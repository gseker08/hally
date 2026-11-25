using FluentValidation;
using Hally.Api.Auth;
using Hally.Api.Common;
using Hally.Api.Features.Messages;
using Hally.Domain.Common;
using Hally.Domain.Points;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.Points;

public record ChoreDto(Guid Id, string Title, int Points, Guid? ChildId);

public record RewardDto(Guid Id, string Title, int Cost);

/// <param name="DoneToday">Chore id → the ledger entry that counted it today (to undo).</param>
public record ChildPointsDto(Guid ChildId, int Balance, int WeekPoints, IReadOnlyDictionary<Guid, Guid> DoneToday);

public record PointsBoardDto(IReadOnlyList<ChoreDto> Chores, IReadOnlyList<RewardDto> Rewards, IReadOnlyList<ChildPointsDto> Children);

public record PointEntryDto(Guid Id, string Kind, string Title, int Points, DateOnly Day, DateTimeOffset At, string? ByName);

public record ChoreRequest(string Title, int Points, Guid? ChildId = null);

public record RewardRequest(string Title, int Cost);

/// <summary>Live note that chores, rewards or stars changed; apps reload the board.</summary>
public record PointsEvent(Guid FamilyId);

public class ChoreRequestValidator : AbstractValidator<ChoreRequest>
{
    public ChoreRequestValidator()
    {
        RuleFor(x => x.Title).NotEmpty().MaximumLength(60);
        RuleFor(x => x.Points).InclusiveBetween(1, 50);
    }
}

public class RewardRequestValidator : AbstractValidator<RewardRequest>
{
    public RewardRequestValidator()
    {
        RuleFor(x => x.Title).NotEmpty().MaximumLength(60);
        RuleFor(x => x.Cost).InclusiveBetween(1, 1000);
    }
}

/// <summary>
/// Chore stars: parents set chores worth stars and rewards that cost stars (allowance, an outing). Ticking a chore adds
/// its stars to the child (once per child per day), a reward takes them away. Every change goes out live on
/// <c>/hubs/chat</c> (<c>PointsChanged</c>).
/// </summary>
[ApiController]
[Authorize(Policy = Policies.FamilyMember)]
[Route("api/v1/families/{familyId:guid}")]
public class PointsController(HallyDbContext db, IHubContext<ChatHub, IChatClient> hub, TimeProvider clock, ILogger<PointsController> logger) : ControllerBase
{
    [CaregiverAllowed]
    [HttpGet("points")]
    public async Task<PointsBoardDto> Board(Guid familyId, CancellationToken ct)
    {
        var tz = await db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.TimeZoneId).FirstAsync(ct);
        var today = FamilyTimeZone.LocalDate(clock.GetUtcNow(), tz);
        var weekStart = today.AddDays(-(((int)today.DayOfWeek + 6) % 7));
        var chores = await db.Chores.AsNoTracking().Where(c => c.FamilyId == familyId).OrderBy(c => c.CreatedAt)
            .Select(c => new ChoreDto(c.Id, c.Title, c.Points, c.ChildId)).ToListAsync(ct);
        var rewards = await db.Rewards.AsNoTracking().Where(r => r.FamilyId == familyId).OrderBy(r => r.Cost)
            .Select(r => new RewardDto(r.Id, r.Title, r.Cost)).ToListAsync(ct);
        var childIds = await db.Children.AsNoTracking().Where(c => c.FamilyId == familyId).OrderBy(c => c.CreatedAt).Select(c => c.Id).ToListAsync(ct);
        var balances = await db.PointEntries.AsNoTracking().Where(p => p.FamilyId == familyId).GroupBy(p => p.ChildId)
            .Select(g => new { ChildId = g.Key, Balance = g.Sum(p => p.Points), Week = g.Where(p => p.Points > 0 && p.Day >= weekStart).Sum(p => p.Points) })
            .ToDictionaryAsync(x => x.ChildId, ct);
        var doneToday = await db.PointEntries.AsNoTracking().Where(p => p.FamilyId == familyId && p.Day == today && p.ChoreId != null)
            .Select(p => new { p.ChildId, ChoreId = p.ChoreId!.Value, p.Id }).ToListAsync(ct);
        var children = childIds.Select(id => new ChildPointsDto(id, balances.GetValueOrDefault(id)?.Balance ?? 0, balances.GetValueOrDefault(id)?.Week ?? 0,
            doneToday.Where(d => d.ChildId == id).ToDictionary(d => d.ChoreId, d => d.Id))).ToList();
        var access = HttpContext.Access();
        return new PointsBoardDto(chores.Where(c => c.ChildId is not { } id || access.SeesChild(id)).ToList(), rewards,
            children.Where(c => access.SeesChild(c.ChildId)).ToList());
    }

    /// <summary>The child's latest 50 ledger lines, newest first.</summary>
    [CaregiverAllowed]
    [HttpGet("children/{childId:guid}/points")]
    public async Task<IReadOnlyList<PointEntryDto>> History(Guid familyId, Guid childId, CancellationToken ct)
    {
        await EnsureChild(familyId, childId, ct);
        var entries = await db.PointEntries.AsNoTracking().Where(p => p.ChildId == childId).OrderByDescending(p => p.CreatedAt).Take(50).ToListAsync(ct);
        var ids = entries.Select(e => e.ByUserId).OfType<Guid>().Distinct().ToList();
        var names = await db.Users.AsNoTracking().Where(u => ids.Contains(u.Id)).ToDictionaryAsync(u => u.Id, u => u.DisplayName, ct);
        return entries.Select(e => new PointEntryDto(e.Id, e.Kind.ToString(), e.Title, e.Points, e.Day, e.CreatedAt,
            e.ByUserId is { } u ? names.GetValueOrDefault(u) : null)).ToList();
    }

    [HttpPost("chores")]
    [ProducesResponseType<ChoreDto>(201)]
    public async Task<IActionResult> AddChore(Guid familyId, ChoreRequest request, CancellationToken ct)
    {
        if (request.ChildId is { } c)
        {
            await EnsureChild(familyId, c, ct);
        }

        var chore = new Chore(familyId, request.Title, request.Points, request.ChildId, clock.GetUtcNow());
        db.Chores.Add(chore);
        await db.SaveChangesAsync(ct);
        await Announce(familyId, ct);
        return StatusCode(201, new ChoreDto(chore.Id, chore.Title, chore.Points, chore.ChildId));
    }

    [HttpPut("chores/{choreId:guid}")]
    public async Task<ChoreDto> UpdateChore(Guid familyId, Guid choreId, ChoreRequest request, CancellationToken ct)
    {
        var chore = await db.Chores.FirstOrDefaultAsync(c => c.Id == choreId && c.FamilyId == familyId, ct)
                    ?? throw new NotFoundException("chore.not_found", "Chore not found.");
        if (request.ChildId is { } c)
        {
            await EnsureChild(familyId, c, ct);
        }

        chore.Update(request.Title, request.Points, request.ChildId);
        await db.SaveChangesAsync(ct);
        await Announce(familyId, ct);
        return new ChoreDto(chore.Id, chore.Title, chore.Points, chore.ChildId);
    }

    /// <summary>Stars already earned stay; the history keeps the title.</summary>
    [HttpDelete("chores/{choreId:guid}")]
    public async Task<IActionResult> DeleteChore(Guid familyId, Guid choreId, CancellationToken ct)
    {
        var chore = await db.Chores.FirstOrDefaultAsync(c => c.Id == choreId && c.FamilyId == familyId, ct)
                    ?? throw new NotFoundException("chore.not_found", "Chore not found.");
        db.Chores.Remove(chore);
        await db.SaveChangesAsync(ct);
        await Announce(familyId, ct);
        return NoContent();
    }

    [HttpPost("rewards")]
    [ProducesResponseType<RewardDto>(201)]
    public async Task<IActionResult> AddReward(Guid familyId, RewardRequest request, CancellationToken ct)
    {
        var reward = new Reward(familyId, request.Title, request.Cost, clock.GetUtcNow());
        db.Rewards.Add(reward);
        await db.SaveChangesAsync(ct);
        await Announce(familyId, ct);
        return StatusCode(201, new RewardDto(reward.Id, reward.Title, reward.Cost));
    }

    [HttpDelete("rewards/{rewardId:guid}")]
    public async Task<IActionResult> DeleteReward(Guid familyId, Guid rewardId, CancellationToken ct)
    {
        var reward = await db.Rewards.FirstOrDefaultAsync(r => r.Id == rewardId && r.FamilyId == familyId, ct)
                     ?? throw new NotFoundException("reward.not_found", "Reward not found.");
        db.Rewards.Remove(reward);
        await db.SaveChangesAsync(ct);
        await Announce(familyId, ct);
        return NoContent();
    }

    /// <summary>Ticks a chore for today. Already ticked today (maybe by the other parent) is not an error.</summary>
    [CaregiverAllowed]
    [HttpPost("children/{childId:guid}/chores/{choreId:guid}/done")]
    public async Task<PointsBoardDto> Done(Guid familyId, Guid childId, Guid choreId, CancellationToken ct)
    {
        await EnsureChild(familyId, childId, ct);
        var chore = await db.Chores.FirstOrDefaultAsync(c => c.Id == choreId && c.FamilyId == familyId, ct)
                    ?? throw new NotFoundException("chore.not_found", "Chore not found.");
        var day = await Today(familyId, ct);
        if (!await db.PointEntries.AnyAsync(p => p.ChoreId == choreId && p.ChildId == childId && p.Day == day, ct))
        {
            db.PointEntries.Add(PointEntry.ForChore(chore, childId, User.UserId(), day, clock.GetUtcNow()));
            try
            {
                await db.SaveChangesAsync(ct);
            }
            catch (DbUpdateException)
            {
                // The other parent ticked it at the same moment: the unique index kept one.
                db.ChangeTracker.Clear();
            }
        }

        await Announce(familyId, ct);
        return await Board(familyId, ct);
    }

    /// <summary>Spends stars on a reward; 422 when the child does not have enough.</summary>
    [HttpPost("children/{childId:guid}/rewards/{rewardId:guid}/redeem")]
    public async Task<PointsBoardDto> Redeem(Guid familyId, Guid childId, Guid rewardId, CancellationToken ct)
    {
        await EnsureChild(familyId, childId, ct);
        var reward = await db.Rewards.FirstOrDefaultAsync(r => r.Id == rewardId && r.FamilyId == familyId, ct)
                     ?? throw new NotFoundException("reward.not_found", "Reward not found.");
        await using var tx = await db.Database.BeginTransactionAsync(System.Data.IsolationLevel.Serializable, ct);
        var balance = await db.PointEntries.Where(p => p.ChildId == childId).SumAsync(p => p.Points, ct);
        db.PointEntries.Add(PointEntry.ForReward(reward, childId, balance, User.UserId(), await Today(familyId, ct), clock.GetUtcNow()));
        await db.SaveChangesAsync(ct);
        await tx.CommitAsync(ct);
        await Announce(familyId, ct);
        return await Board(familyId, ct);
    }

    /// <summary>Undoes a ledger line (a chore ticked by mistake, a reward given back).</summary>
    [HttpDelete("children/{childId:guid}/points/{entryId:guid}")]
    public async Task<PointsBoardDto> Undo(Guid familyId, Guid childId, Guid entryId, CancellationToken ct)
    {
        var entry = await db.PointEntries.FirstOrDefaultAsync(p => p.Id == entryId && p.ChildId == childId && p.FamilyId == familyId, ct)
                    ?? throw new NotFoundException("points.not_found", "Entry not found.");
        db.PointEntries.Remove(entry);
        await db.SaveChangesAsync(ct);
        await Announce(familyId, ct);
        return await Board(familyId, ct);
    }

    private async Task<DateOnly> Today(Guid familyId, CancellationToken ct)
    {
        var tz = await db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.TimeZoneId).FirstAsync(ct);
        return FamilyTimeZone.LocalDate(clock.GetUtcNow(), tz);
    }

    private async Task Announce(Guid familyId, CancellationToken ct)
    {
        try
        {
            var adults = await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == familyId).Select(m => m.UserId).ToListAsync(ct);
            await hub.Clients.Groups(adults.Select(ChatHub.UserGroup).ToList()).PointsChanged(new PointsEvent(familyId));
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Realtime points event failed");
        }
    }

    private async Task EnsureChild(Guid familyId, Guid childId, CancellationToken ct)
    {
        if (!await db.Children.AnyAsync(c => c.FamilyId == familyId && c.Id == childId, ct))
        {
            throw new NotFoundException("child.not_found", "Child not found.");
        }
    }
}
