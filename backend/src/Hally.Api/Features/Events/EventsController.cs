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

namespace Hally.Api.Features.Events;

/// <summary>An event or, for a series, one occurrence of it (same <c>Id</c>; <c>SeriesStartsAt</c> is the first occurrence).</summary>
/// <param name="ChildId">The first of <c>ChildIds</c>, kept for older clients.</param>
public record EventDto(Guid Id, string Title, DateTimeOffset StartsAt, DateTimeOffset? EndsAt, bool AllDay, string? Location, Guid? ChildId, Guid? SourceProposalId,
    EventRepeat Repeat, DateOnly? RepeatUntil, DateTimeOffset SeriesStartsAt, IReadOnlyList<Guid> ChildIds);
/// <summary>For a series, <c>StartsAt</c> is the first occurrence. <c>Repeat</c> defaults to <c>None</c>.</summary>
public record SaveEventRequest(string Title, DateTimeOffset StartsAt, DateTimeOffset? EndsAt, bool AllDay, string? Location, Guid? ChildId,
    EventRepeat Repeat = EventRepeat.None, DateOnly? RepeatUntil = null, IReadOnlyList<Guid>? ChildIds = null)
{
    /// <summary>The children the event is about; empty for the whole family. <c>ChildIds</c> wins over the older single <c>ChildId</c>.</summary>
    public IReadOnlyList<Guid> EffectiveChildIds => ChildIds ?? (ChildId is { } c ? [c] : []);
}

public record SavedEventDto(EventDto Event, IReadOnlyList<EventDto> Conflicts);

public class SaveEventRequestValidator : AbstractValidator<SaveEventRequest>
{
    public SaveEventRequestValidator()
    {
        RuleFor(x => x.Title).NotEmpty().MaximumLength(200);
        RuleFor(x => x.Location).MaximumLength(200);
        RuleFor(x => x.EndsAt).GreaterThanOrEqualTo(x => x.StartsAt).When(x => x.EndsAt.HasValue);
        RuleFor(x => x.Repeat).IsInEnum();
        RuleFor(x => x.ChildIds!.Count).LessThanOrEqualTo(ChildTags.Max).When(x => x.ChildIds is not null);
    }
}

[ApiController]
[Authorize(Policy = Policies.FamilyMember)]
[Route("api/v1/families/{familyId:guid}/events")]
public class EventsController(HallyDbContext db, IAnalytics analytics, TimeProvider clock) : ControllerBase
{
    /// <summary>Events overlapping [from, to). Defaults to the next 31 days. <c>child</c> keeps only events tagged with that child.</summary>
    [HttpGet]
    public async Task<ActionResult<IReadOnlyList<EventDto>>> List(Guid familyId, [FromQuery] DateTimeOffset? from, [FromQuery] DateTimeOffset? to,
        [FromQuery] Guid? child, CancellationToken ct)
    {
        var start = from ?? clock.GetUtcNow();
        var end = to ?? start.AddDays(31);
        if (end <= start || end - start > TimeSpan.FromDays(400))
        {
            return Problem(statusCode: 400, title: "Range must be positive and at most 400 days.", type: "https://hally.app/problems/events.range_invalid");
        }

        return (await InRange(familyId, start, end, ct)).Where(e => child is not { } c || e.ChildIds.Contains(c)).Select(ToDto).ToList();
    }

    [HttpPost]
    [Idempotent]
    [ProducesResponseType<SavedEventDto>(201)]
    public async Task<IActionResult> Create(Guid familyId, SaveEventRequest request, CancellationToken ct)
    {
        await EnsureChildren(familyId, request.EffectiveChildIds, ct);
        var userId = User.UserId();
        var evt = new CalendarEvent(familyId, userId, request.Title, request.StartsAt, request.EndsAt, request.AllDay, request.Location, request.EffectiveChildIds);
        evt.SetRepeat(request.Repeat, request.RepeatUntil);
        var conflicts = await Conflicts(familyId, evt, ct);
        db.Events.Add(evt);
        db.AuditEntries.Add(new AuditEntry { FamilyId = familyId, ActorUserId = userId, Action = "event.created", EntityType = "event", EntityId = evt.Id, At = clock.GetUtcNow() });
        analytics.Track(AnalyticsEvents.EventCreated, userId, familyId, new Dictionary<string, object?> { ["source"] = "manual" });
        await db.SaveChangesAsync(ct);
        return StatusCode(201, new SavedEventDto(ToDto(evt), conflicts));
    }

    [HttpPut("{eventId:guid}")]
    public async Task<ActionResult<SavedEventDto>> Update(Guid familyId, Guid eventId, SaveEventRequest request, CancellationToken ct)
    {
        await EnsureChildren(familyId, request.EffectiveChildIds, ct);
        var evt = await db.Events.FirstOrDefaultAsync(e => e.Id == eventId && e.FamilyId == familyId, ct)
                  ?? throw new NotFoundException("event.not_found", "Event not found.");
        evt.Update(request.Title, request.StartsAt, request.EndsAt, request.AllDay, request.Location, request.EffectiveChildIds);
        evt.SetRepeat(request.Repeat, request.RepeatUntil);
        db.AuditEntries.Add(new AuditEntry { FamilyId = familyId, ActorUserId = User.UserId(), Action = "event.updated", EntityType = "event", EntityId = evt.Id, At = clock.GetUtcNow() });
        await db.SaveChangesAsync(ct);
        return new SavedEventDto(ToDto(evt), await Conflicts(familyId, evt, ct));
    }

    [HttpDelete("{eventId:guid}")]
    public async Task<IActionResult> Delete(Guid familyId, Guid eventId, CancellationToken ct)
    {
        var evt = await db.Events.FirstOrDefaultAsync(e => e.Id == eventId && e.FamilyId == familyId, ct)
                  ?? throw new NotFoundException("event.not_found", "Event not found.");
        db.Events.Remove(evt);
        db.AuditEntries.Add(new AuditEntry { FamilyId = familyId, ActorUserId = User.UserId(), Action = "event.deleted", EntityType = "event", EntityId = evt.Id, At = clock.GetUtcNow() });
        await db.SaveChangesAsync(ct);
        return NoContent();
    }

    private async Task<List<CalendarEvent>> InRange(Guid familyId, DateTimeOffset start, DateTimeOffset end, CancellationToken ct) =>
        await db.EventsInRangeAsync(familyId, start, end, await db.FamilyTimeZoneAsync(familyId, ct), ct);

    /// <summary>Overlaps with the event's first occurrence (for a series, later clashes are not checked).</summary>
    private async Task<IReadOnlyList<EventDto>> Conflicts(Guid familyId, CalendarEvent evt, CancellationToken ct) =>
        evt.AllDay ? [] : (await InRange(familyId, evt.StartsAt, evt.EffectiveEnd, ct))
            .Where(e => e.Id != evt.Id && !e.AllDay).Select(ToDto).ToList();

    private async Task EnsureChildren(Guid familyId, IReadOnlyList<Guid> children, CancellationToken ct)
    {
        if (!await db.AllChildrenInFamilyAsync(familyId, children, ct))
        {
            throw new Domain.Common.DomainException("event.child_not_in_family", "The child does not belong to this family.");
        }
    }

    public static EventDto ToDto(CalendarEvent e) =>
        new(e.Id, e.Title, e.StartsAt, e.EndsAt, e.AllDay, e.Location, e.ChildIds.Count > 0 ? e.ChildIds[0] : null, e.SourceProposalId, e.Repeat, e.RepeatUntil, e.SeriesStartsAt, e.ChildIds);
}
