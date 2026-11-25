using FluentValidation;
using Hally.Api.Auth;
using Hally.Api.Common;
using Hally.Api.Features.Families;
using Hally.Domain.Planning;
using Hally.Infrastructure.Analytics;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.Tasks;

/// <param name="ChildId">The first of <c>ChildIds</c>, kept for older clients.</param>
public record TaskDto(Guid Id, string Title, string? Notes, DateTimeOffset? DueAt, bool AllDay, Guid? AssigneeUserId, Guid? ChildId,
    string State, bool IsOverdue, DateTimeOffset? CompletedAt, Guid? SourceProposalId, IReadOnlyList<Guid> ChildIds);

/// <param name="ChildIds">The children the task is about; empty for the whole family. Wins over the older single <c>ChildId</c>.</param>
public record SaveTaskRequest(string Title, string? Notes, DateTimeOffset? DueAt, bool AllDay, Guid? AssigneeUserId, Guid? ChildId,
    IReadOnlyList<Guid>? ChildIds = null)
{
    public IReadOnlyList<Guid> EffectiveChildIds => ChildIds ?? (ChildId is { } c ? [c] : []);
}

public class SaveTaskRequestValidator : AbstractValidator<SaveTaskRequest>
{
    public SaveTaskRequestValidator()
    {
        RuleFor(x => x.Title).NotEmpty().MaximumLength(200);
        RuleFor(x => x.Notes).MaximumLength(2000);
        RuleFor(x => x.ChildIds!.Count).LessThanOrEqualTo(Domain.Planning.ChildTags.Max).When(x => x.ChildIds is not null);
    }
}

[ApiController]
[Authorize(Policy = Policies.FamilyMember)]
[Route("api/v1/families/{familyId:guid}/tasks")]
public class TasksController(HallyDbContext db, IAnalytics analytics, TimeProvider clock) : ControllerBase
{
    [CaregiverAllowed]
    [HttpGet]
    public async Task<ActionResult<IReadOnlyList<TaskDto>>> List(Guid familyId, [FromQuery] string? state, [FromQuery] Guid? assignee,
        [FromQuery] Guid? child, [FromQuery] int page = 1, [FromQuery] int pageSize = 50, CancellationToken ct = default)
    {
        pageSize = Math.Clamp(pageSize, 1, 200);
        var query = db.Tasks.AsNoTracking().Where(t => t.FamilyId == familyId);
        if (Enum.TryParse<TaskState>(state, true, out var s))
        {
            query = query.Where(t => t.State == s);
        }

        if (assignee is { } a)
        {
            query = query.Where(t => t.AssigneeUserId == a);
        }

        if (child is { } c)
        {
            query = query.Where(t => t.ChildIds.Contains(c));
        }

        var items = await query.OrderBy(t => t.DueAt == null).ThenBy(t => t.DueAt).ThenBy(t => t.CreatedAt)
            .Skip((Math.Max(page, 1) - 1) * pageSize).Take(pageSize).ToListAsync(ct);
        var now = clock.GetUtcNow();
        var access = HttpContext.Access();
        return items.Where(t => access.SeesTagged(t.ChildIds)).Select(t => ToDto(t, now)).ToList();
    }

    [CaregiverAllowed]
    [HttpGet("{taskId:guid}")]
    public async Task<ActionResult<TaskDto>> Get(Guid familyId, Guid taskId, CancellationToken ct) =>
        ToDto(await Find(familyId, taskId, ct, track: false), clock.GetUtcNow());

    [HttpPost]
    [Idempotent]
    [ProducesResponseType<TaskDto>(201)]
    public async Task<IActionResult> Create(Guid familyId, SaveTaskRequest request, CancellationToken ct)
    {
        await EnsureRefs(familyId, request.AssigneeUserId, request.EffectiveChildIds, ct);
        var userId = User.UserId();
        var task = new FamilyTask(familyId, userId, request.Title, request.Notes, request.DueAt, request.AllDay, request.AssigneeUserId, request.EffectiveChildIds);
        db.Tasks.Add(task);
        Audit(familyId, userId, "task.created", task.Id);
        analytics.Track(AnalyticsEvents.TaskCreated, userId, familyId, new Dictionary<string, object?> { ["source"] = "manual" });
        await db.SaveChangesAsync(ct);
        return StatusCode(201, ToDto(task, clock.GetUtcNow()));
    }

    [HttpPut("{taskId:guid}")]
    public async Task<ActionResult<TaskDto>> Update(Guid familyId, Guid taskId, SaveTaskRequest request, CancellationToken ct)
    {
        await EnsureRefs(familyId, request.AssigneeUserId, request.EffectiveChildIds, ct);
        var task = await Find(familyId, taskId, ct);
        task.Update(request.Title, request.Notes, request.DueAt, request.AllDay, request.EffectiveChildIds);
        task.Assign(request.AssigneeUserId);
        Audit(familyId, User.UserId(), "task.updated", task.Id);
        await db.SaveChangesAsync(ct);
        return ToDto(task, clock.GetUtcNow());
    }

    [CaregiverAllowed]
    [HttpPost("{taskId:guid}/complete")]
    [Idempotent]
    public async Task<ActionResult<TaskDto>> Complete(Guid familyId, Guid taskId, CancellationToken ct)
    {
        var task = await Find(familyId, taskId, ct);
        var userId = User.UserId();
        task.Complete(userId, clock.GetUtcNow());
        Audit(familyId, userId, "task.completed", task.Id);
        analytics.Track(AnalyticsEvents.TaskCompleted, userId, familyId);
        await db.SaveChangesAsync(ct);
        return ToDto(task, clock.GetUtcNow());
    }

    [CaregiverAllowed]
    [HttpPost("{taskId:guid}/reopen")]
    [Idempotent]
    public async Task<ActionResult<TaskDto>> Reopen(Guid familyId, Guid taskId, CancellationToken ct)
    {
        var task = await Find(familyId, taskId, ct);
        task.Reopen();
        Audit(familyId, User.UserId(), "task.reopened", task.Id);
        await db.SaveChangesAsync(ct);
        return ToDto(task, clock.GetUtcNow());
    }

    [HttpPost("{taskId:guid}/cancel")]
    [Idempotent]
    public async Task<ActionResult<TaskDto>> Cancel(Guid familyId, Guid taskId, CancellationToken ct)
    {
        var task = await Find(familyId, taskId, ct);
        task.Cancel();
        Audit(familyId, User.UserId(), "task.cancelled", task.Id);
        await db.SaveChangesAsync(ct);
        return ToDto(task, clock.GetUtcNow());
    }

    private async Task<FamilyTask> Find(Guid familyId, Guid taskId, CancellationToken ct, bool track = true)
    {
        var q = track ? db.Tasks : db.Tasks.AsNoTracking();
        var task = await q.FirstOrDefaultAsync(t => t.Id == taskId && t.FamilyId == familyId, ct);
        return task is not null && HttpContext.Access().SeesTagged(task.ChildIds)
            ? task
            : throw new NotFoundException("task.not_found", "Task not found.");
    }

    private async Task EnsureRefs(Guid familyId, Guid? assignee, IReadOnlyList<Guid> children, CancellationToken ct)
    {
        if (assignee is { } a && !await db.FamilyMembers.AnyAsync(m => m.FamilyId == familyId && m.UserId == a, ct))
        {
            throw new Domain.Common.DomainException("task.assignee_not_member", "The assignee is not a member of this family.");
        }

        if (!await db.AllChildrenInFamilyAsync(familyId, children, ct))
        {
            throw new Domain.Common.DomainException("task.child_not_in_family", "The child does not belong to this family.");
        }
    }

    private void Audit(Guid familyId, Guid userId, string action, Guid id) =>
        db.AuditEntries.Add(new AuditEntry { FamilyId = familyId, ActorUserId = userId, Action = action, EntityType = "task", EntityId = id, At = clock.GetUtcNow() });

    public static TaskDto ToDto(FamilyTask t, DateTimeOffset now) =>
        new(t.Id, t.Title, t.Notes, t.DueAt, t.AllDay, t.AssigneeUserId, t.ChildIds.Count > 0 ? t.ChildIds[0] : null, t.State.ToString(), t.IsOverdue(now), t.CompletedAt, t.SourceProposalId, t.ChildIds);
}
