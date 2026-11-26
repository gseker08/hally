using FluentValidation;
using Hally.Api.Auth;
using Hally.Api.Common;
using Hally.Domain.Planning;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.CalendarSync;

/// <param name="Mine">True for the caller's own shared events (the app shows those live from the phone instead).</param>
public record ExternalEventDto(Guid Id, Guid OwnerUserId, string OwnerName, bool Mine, string Provider, string CalendarName, string? Title, bool BusyOnly,
    DateTimeOffset StartsAt, DateTimeOffset EndsAt, bool AllDay, string? ColorHex);

public record ExternalEventInput(string SourceKey, ExternalProvider Provider, string CalendarName, string? Title, bool BusyOnly,
    DateTimeOffset StartsAt, DateTimeOffset EndsAt, bool AllDay, string? ColorHex);

/// <summary>Everything the caller shares from their phone calendars right now. It replaces what they shared before.</summary>
public record SyncExternalEventsRequest(IReadOnlyList<ExternalEventInput> Events);

public record SyncExternalEventsResult(int Shared, int Removed);

public class SyncExternalEventsRequestValidator : AbstractValidator<SyncExternalEventsRequest>
{
    public SyncExternalEventsRequestValidator()
    {
        RuleFor(x => x.Events).NotNull();
        RuleFor(x => x.Events.Count).LessThanOrEqualTo(ExternalEventsController.MaxEvents).When(x => x.Events is not null);
        RuleForEach(x => x.Events).ChildRules(e =>
        {
            e.RuleFor(x => x.SourceKey).NotEmpty().MaximumLength(ExternalEvent.MaxSourceKey);
            e.RuleFor(x => x.CalendarName).NotEmpty().MaximumLength(ExternalEvent.MaxCalendarName);
            e.RuleFor(x => x.Provider).IsInEnum();
            e.RuleFor(x => x.EndsAt).GreaterThanOrEqualTo(x => x.StartsAt);
            e.RuleFor(x => x.ColorHex).Matches("^#[0-9A-Fa-f]{6}$").When(x => x.ColorHex is not null);
        });
    }
}

/// <summary>Phone calendar events parents share with their family (read-only copies, see <see cref="ExternalEvent"/>).
/// Parents only: a caregiver neither shares nor sees a parent's own calendar.</summary>
[ApiController]
[Authorize(Policy = Policies.FamilyMember)]
[Route("api/v1/families/{familyId:guid}/external-events")]
public class ExternalEventsController(HallyDbContext db, TimeProvider clock) : ControllerBase
{
    public const int MaxEvents = 2000;

    /// <summary>Shared events overlapping [from, to), from every parent still in the family.</summary>
    [HttpGet]
    public async Task<ActionResult<IReadOnlyList<ExternalEventDto>>> List(Guid familyId, [FromQuery] DateTimeOffset from, [FromQuery] DateTimeOffset to, CancellationToken ct)
    {
        if (to <= from || to - from > TimeSpan.FromDays(400))
        {
            return Problem(statusCode: 400, title: "Range must be positive and at most 400 days.", type: "https://hally.app/problems/events.range_invalid");
        }

        var me = User.UserId();
        var start = from.ToUniversalTime();
        var end = to.ToUniversalTime();
        // EndsAt >= start keeps zero-length events that start inside the window; Overlaps trims the edges.
        var rows = await db.ExternalEvents.AsNoTracking()
            .Where(x => x.FamilyId == familyId && x.StartsAt < end && x.EndsAt >= start)
            .Join(db.FamilyMembers.Where(m => m.FamilyId == familyId), x => x.OwnerUserId, m => m.UserId, (x, m) => x)
            .Join(db.Users, x => x.OwnerUserId, u => u.Id, (x, u) => new { Event = x, u.DisplayName })
            .OrderBy(x => x.Event.StartsAt)
            .ToListAsync(ct);
        return rows.Where(r => r.Event.Overlaps(start, end)).Select(r => new ExternalEventDto(r.Event.Id, r.Event.OwnerUserId, FirstName(r.DisplayName),
            r.Event.OwnerUserId == me, r.Event.Provider.ToString(), r.Event.CalendarName, r.Event.Title, r.Event.BusyOnly,
            r.Event.StartsAt, r.Event.EndsAt, r.Event.AllDay, r.Event.ColorHex)).ToList();
    }

    /// <summary>Replaces the caller's shared events with this set: new ones are added, changed ones updated, missing ones removed.</summary>
    [HttpPut]
    public async Task<ActionResult<SyncExternalEventsResult>> Sync(Guid familyId, SyncExternalEventsRequest request, CancellationToken ct)
    {
        var me = User.UserId();
        var now = clock.GetUtcNow();
        var existing = await db.ExternalEvents.Where(x => x.FamilyId == familyId && x.OwnerUserId == me).ToDictionaryAsync(x => x.SourceKey, ct);
        var incoming = request.Events.GroupBy(e => e.SourceKey.Trim()).Select(g => g.Last()).ToList();
        foreach (var e in incoming)
        {
            if (existing.Remove(e.SourceKey.Trim(), out var row))
            {
                row.Update(e.Provider, e.CalendarName, e.Title, e.BusyOnly, e.StartsAt, e.EndsAt, e.AllDay, e.ColorHex, now);
            }
            else
            {
                db.ExternalEvents.Add(new ExternalEvent(familyId, me, e.SourceKey, e.Provider, e.CalendarName, e.Title, e.BusyOnly, e.StartsAt, e.EndsAt, e.AllDay, e.ColorHex, now));
            }
        }

        db.ExternalEvents.RemoveRange(existing.Values);
        await db.SaveChangesAsync(ct);
        return new SyncExternalEventsResult(incoming.Count, existing.Count);
    }

    /// <summary>Stops sharing: removes all of the caller's shared events.</summary>
    [HttpDelete]
    public async Task<IActionResult> Clear(Guid familyId, CancellationToken ct)
    {
        var me = User.UserId();
        await db.ExternalEvents.Where(x => x.FamilyId == familyId && x.OwnerUserId == me).ExecuteDeleteAsync(ct);
        return NoContent();
    }

    private static string FirstName(string name) => name.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? name;
}
