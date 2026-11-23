using FluentValidation;
using Hally.Api.Auth;
using Hally.Api.Common;
using Hally.Api.Features.Messages;
using Hally.Domain.Common;
using Hally.Domain.Sleep;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.Sleep;

public record SleepEntryDto(Guid Id, Guid ChildId, string Kind, DateTimeOffset StartedAt, DateTimeOffset? EndedAt, int Minutes,
    string? StartedByName, string? EndedByName, string? Note, Guid? StartedByUserId = null);

/// <param name="Asleep">The open sleep, when the child is asleep now.</param>
/// <param name="LastSleep">The most recent finished sleep ("awake for 2 h").</param>
public record ChildSleepStatusDto(Guid ChildId, SleepEntryDto? Asleep, SleepEntryDto? LastSleep);

/// <summary>A sleep day runs 06:00 to 06:00 family time and is named after its first calendar day.</summary>
public record SleepDayDto(DateOnly Date, int NightMinutes, int NapMinutes, int Naps);

public record ChildSleepHistoryDto(Guid ChildId, IReadOnlyList<SleepDayDto> Days, IReadOnlyList<SleepEntryDto> Entries, int AverageNightMinutes, int AverageNapMinutes);

/// <param name="At">Defaults to now; earlier for "she fell asleep 20 minutes ago".</param>
/// <param name="Kind">Night or Nap; guessed from the time when left out.</param>
public record SleepStartRequest(DateTimeOffset? At = null, SleepKind? Kind = null);

public record SleepStopRequest(DateTimeOffset? At = null, string? Note = null);

public record AddSleepRequest(DateTimeOffset StartedAt, DateTimeOffset EndedAt, SleepKind? Kind = null, string? Note = null);

/// <summary>Live note that a child's sleep changed; apps reload.</summary>
public record SleepEvent(Guid FamilyId, Guid ChildId);

public class SleepStopRequestValidator : AbstractValidator<SleepStopRequest>
{
    public SleepStopRequestValidator() => RuleFor(x => x.Note).MaximumLength(200);
}

public class AddSleepRequestValidator : AbstractValidator<AddSleepRequest>
{
    public AddSleepRequestValidator()
    {
        RuleFor(x => x.Note).MaximumLength(200);
        RuleFor(x => x).Must(x => x.EndedAt > x.StartedAt).WithMessage("EndedAt must be after StartedAt.");
    }
}

/// <summary>
/// Sleep log per child: "asleep" and "awake" taps (either parent, shared live over <c>/hubs/chat</c> as
/// <c>SleepChanged</c>), sleeps added afterwards, and a daily summary of night sleep and naps.
/// </summary>
[ApiController]
[Authorize(Policy = Policies.FamilyMember)]
[Route("api/v1/families/{familyId:guid}")]
public class SleepController(HallyDbContext db, IHubContext<ChatHub, IChatClient> hub, TimeProvider clock, ILogger<SleepController> logger) : ControllerBase
{
    /// <summary>Is each child asleep now, and when did they last sleep.</summary>
    [HttpGet("sleep")]
    public async Task<IReadOnlyList<ChildSleepStatusDto>> Status(Guid familyId, CancellationToken ct)
    {
        var children = await db.Children.AsNoTracking().Where(c => c.FamilyId == familyId).OrderBy(c => c.CreatedAt).Select(c => c.Id).ToListAsync(ct);
        var result = new List<ChildSleepStatusDto>();
        foreach (var childId in children)
        {
            result.Add(await StatusAsync(childId, ct));
        }

        return result;
    }

    /// <summary>The last <paramref name="days"/> sleep days (oldest first) with their entries, newest first.</summary>
    [HttpGet("children/{childId:guid}/sleep")]
    public async Task<ChildSleepHistoryDto> History(Guid familyId, Guid childId, [FromQuery] int days = 7, CancellationToken ct = default)
    {
        await EnsureChild(familyId, childId, ct);
        days = Math.Clamp(days, 1, 31);
        var tz = await db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.TimeZoneId).FirstAsync(ct);
        var now = clock.GetUtcNow();
        var today = SleepEntry.SleepDay(now, tz);
        var first = today.AddDays(-(days - 1));
        var from = FamilyTimeZone.StartOfDay(first, tz) + SleepEntry.DayStartsAt;
        var entries = await db.SleepEntries.AsNoTracking().Where(e => e.ChildId == childId && e.StartedAt >= from)
            .OrderByDescending(e => e.StartedAt).ToListAsync(ct);
        var names = await Names(entries, ct);
        var dayList = Enumerable.Range(0, days).Select(i => first.AddDays(i)).Select(d =>
        {
            var on = entries.Where(e => SleepEntry.SleepDay(e.StartedAt, tz) == d).ToList();
            return new SleepDayDto(d,
                (int)on.Where(e => e.Kind == SleepKind.Night).Sum(e => e.Duration(now).TotalMinutes),
                (int)on.Where(e => e.Kind == SleepKind.Nap).Sum(e => e.Duration(now).TotalMinutes),
                on.Count(e => e.Kind == SleepKind.Nap));
        }).ToList();
        // Averages over finished days that have a record, so today's half night does not pull them down.
        var counted = dayList.Where(d => d.Date < today && d.NightMinutes + d.NapMinutes > 0).ToList();
        return new ChildSleepHistoryDto(childId, dayList, entries.Select(e => Dto(e, names, now)).ToList(),
            counted.Count == 0 ? 0 : (int)counted.Average(d => d.NightMinutes),
            counted.Count == 0 ? 0 : (int)counted.Average(d => d.NapMinutes));
    }

    /// <summary>"Fell asleep". Already asleep is not an error: the open sleep comes back.</summary>
    [HttpPost("children/{childId:guid}/sleep/start")]
    public async Task<ChildSleepStatusDto> Start(Guid familyId, Guid childId, SleepStartRequest request, CancellationToken ct)
    {
        await EnsureChild(familyId, childId, ct);
        if (!await db.SleepEntries.AnyAsync(e => e.ChildId == childId && e.EndedAt == null, ct))
        {
            var now = clock.GetUtcNow();
            var at = request.At ?? now;
            var tz = await db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.TimeZoneId).FirstAsync(ct);
            var kind = request.Kind ?? SleepEntry.GuessKind(FamilyTimeZone.ToFamilyTime(at, tz));
            db.SleepEntries.Add(new SleepEntry(familyId, childId, User.UserId(), kind, at, null, null, now));
            try
            {
                await db.SaveChangesAsync(ct);
            }
            catch (DbUpdateException)
            {
                // The other parent tapped at the same moment; the unique index kept theirs.
                db.ChangeTracker.Clear();
            }
        }

        return await Changed(familyId, childId, ct);
    }

    /// <summary>"Woke up". Not asleep is not an error.</summary>
    [HttpPost("children/{childId:guid}/sleep/stop")]
    public async Task<ChildSleepStatusDto> Stop(Guid familyId, Guid childId, SleepStopRequest request, CancellationToken ct)
    {
        await EnsureChild(familyId, childId, ct);
        var open = await db.SleepEntries.FirstOrDefaultAsync(e => e.ChildId == childId && e.EndedAt == null, ct);
        if (open is not null)
        {
            var now = clock.GetUtcNow();
            open.End(User.UserId(), request.At ?? now, now);
            if (request.Note is not null)
            {
                open.SetNote(request.Note);
            }

            await db.SaveChangesAsync(ct);
        }

        return await Changed(familyId, childId, ct);
    }

    /// <summary>Adds a finished sleep afterwards. Overlapping an existing sleep is refused.</summary>
    [HttpPost("children/{childId:guid}/sleep/entries")]
    [ProducesResponseType<SleepEntryDto>(201)]
    public async Task<IActionResult> Add(Guid familyId, Guid childId, AddSleepRequest request, CancellationToken ct)
    {
        await EnsureChild(familyId, childId, ct);
        var now = clock.GetUtcNow();
        var overlaps = await db.SleepEntries.AnyAsync(e => e.ChildId == childId && e.StartedAt < request.EndedAt
                                                                                && (e.EndedAt == null || e.EndedAt > request.StartedAt), ct);
        if (overlaps)
        {
            throw new DomainException("sleep.overlap", "This overlaps another sleep.");
        }

        var tz = await db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.TimeZoneId).FirstAsync(ct);
        var kind = request.Kind ?? SleepEntry.GuessKind(FamilyTimeZone.ToFamilyTime(request.StartedAt, tz));
        var entry = new SleepEntry(familyId, childId, User.UserId(), kind, request.StartedAt, request.EndedAt, request.Note, now);
        db.SleepEntries.Add(entry);
        await db.SaveChangesAsync(ct);
        await Changed(familyId, childId, ct);
        return StatusCode(201, Dto(entry, await Names([entry], ct), now));
    }

    [HttpDelete("children/{childId:guid}/sleep/entries/{entryId:guid}")]
    public async Task<IActionResult> Delete(Guid familyId, Guid childId, Guid entryId, CancellationToken ct)
    {
        var entry = await db.SleepEntries.FirstOrDefaultAsync(e => e.Id == entryId && e.ChildId == childId && e.FamilyId == familyId, ct)
                    ?? throw new NotFoundException("sleep.not_found", "Sleep entry not found.");
        db.SleepEntries.Remove(entry);
        await db.SaveChangesAsync(ct);
        await Changed(familyId, childId, ct);
        return NoContent();
    }

    private async Task<ChildSleepStatusDto> StatusAsync(Guid childId, CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        var open = await db.SleepEntries.AsNoTracking().FirstOrDefaultAsync(e => e.ChildId == childId && e.EndedAt == null, ct);
        var last = await db.SleepEntries.AsNoTracking().Where(e => e.ChildId == childId && e.EndedAt != null)
            .OrderByDescending(e => e.EndedAt).FirstOrDefaultAsync(ct);
        var names = await Names(new[] { open, last }.OfType<SleepEntry>(), ct);
        return new ChildSleepStatusDto(childId, open is null ? null : Dto(open, names, now), last is null ? null : Dto(last, names, now));
    }

    private async Task<ChildSleepStatusDto> Changed(Guid familyId, Guid childId, CancellationToken ct)
    {
        try
        {
            var adults = await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == familyId).Select(m => m.UserId).ToListAsync(ct);
            await hub.Clients.Groups(adults.Select(ChatHub.UserGroup).ToList()).SleepChanged(new SleepEvent(familyId, childId));
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Realtime sleep event failed");
        }

        return await StatusAsync(childId, ct);
    }

    private async Task<Dictionary<Guid, string>> Names(IEnumerable<SleepEntry> entries, CancellationToken ct)
    {
        var ids = entries.SelectMany(e => new[] { e.StartedByUserId, e.EndedByUserId }).OfType<Guid>().Distinct().ToList();
        return await db.Users.AsNoTracking().Where(u => ids.Contains(u.Id)).ToDictionaryAsync(u => u.Id, u => u.DisplayName, ct);
    }

    private static SleepEntryDto Dto(SleepEntry e, Dictionary<Guid, string> names, DateTimeOffset now) =>
        new(e.Id, e.ChildId, e.Kind.ToString(), e.StartedAt, e.EndedAt, (int)e.Duration(now).TotalMinutes,
            e.StartedByUserId is { } s ? names.GetValueOrDefault(s) : null,
            e.EndedByUserId is { } en ? names.GetValueOrDefault(en) : null, e.Note, e.StartedByUserId);

    private async Task EnsureChild(Guid familyId, Guid childId, CancellationToken ct)
    {
        if (!await db.Children.AnyAsync(c => c.FamilyId == familyId && c.Id == childId, ct))
        {
            throw new NotFoundException("child.not_found", "Child not found.");
        }
    }
}
