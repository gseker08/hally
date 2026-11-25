using Hally.Api.Auth;
using Hally.Api.Common;
using Hally.Api.Features.Notifications;
using Hally.Domain.Bedtime;
using Hally.Domain.Common;
using Hally.Domain.Families;
using Hally.Domain.Notifications;
using Hally.Domain.Points;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.Bedtime;

public record BedtimeStepDto(string Title, string Emoji);

/// <param name="Time">"HH:mm", family-local.</param>
public record BedtimeRoutineDto(string Time, IReadOnlyList<BedtimeStepDto> Steps, bool Enabled, bool LockUntilMorning, int Cherries);

/// <summary>Tonight on the child's phone.</summary>
/// <param name="Open">The steps can be checked now (from 30 minutes before the time until the morning).</param>
/// <param name="Done">Steps done, in order.</param>
public record ChildBedtimeDto(string Time, IReadOnlyList<BedtimeStepDto> Steps, DateOnly Evening, bool Open, int Done, DateTimeOffset? FinishedAt, int Cherries,
    bool LockUntilMorning);

/// <param name="Routine">Null until a parent sets one up.</param>
/// <param name="Tonight">Tonight's progress, when the child started.</param>
public record BedtimeDto(BedtimeRoutineDto? Routine, BedtimeTonightDto? Tonight);

public record BedtimeTonightDto(DateOnly Evening, int Done, int Total, DateTimeOffset? FinishedAt);

public class BedtimeService(HallyDbContext db, NotificationPublisher publisher, TimeProvider clock, ILogger<BedtimeService> logger)
{
    /// <summary>Tonight for the child's phone; null without an enabled routine.</summary>
    public async Task<ChildBedtimeDto?> ChildAsync(Guid childId, string timeZoneId, CancellationToken ct)
    {
        var routine = await db.BedtimeRoutines.AsNoTracking().FirstOrDefaultAsync(r => r.ChildId == childId && r.Enabled, ct);
        if (routine is null)
        {
            return null;
        }

        var local = FamilyTimeZone.ToFamilyTime(clock.GetUtcNow(), timeZoneId);
        var evening = BedtimeRoutine.EveningOf(local);
        var run = await db.BedtimeRuns.AsNoTracking().FirstOrDefaultAsync(r => r.ChildId == childId && r.Evening == evening, ct);
        return new ChildBedtimeDto(routine.Time.ToString("HH:mm"), routine.Steps.Select(s => new BedtimeStepDto(s.Title, s.Emoji)).ToList(), evening,
            routine.IsOpen(local), run?.Done ?? 0, run?.FinishedAt, routine.Cherries, routine.LockUntilMorning);
    }

    /// <summary>The phone stays locked from the end of the routine until <see cref="BedtimeRoutine.MorningUnlock"/>.</summary>
    public async Task<bool> NightLockedAsync(Guid childId, string timeZoneId, CancellationToken ct)
    {
        var local = FamilyTimeZone.ToFamilyTime(clock.GetUtcNow(), timeZoneId);
        if (local.Hour < BedtimeRoutine.EveningStartsHour && TimeOnly.FromDateTime(local.DateTime) >= BedtimeRoutine.MorningUnlock)
        {
            return false;
        }

        var evening = BedtimeRoutine.EveningOf(local);
        return await db.BedtimeRoutines.AnyAsync(r => r.ChildId == childId && r.Enabled && r.LockUntilMorning, ct)
               && await db.BedtimeRuns.AnyAsync(r => r.ChildId == childId && r.Evening == evening && r.FinishedAt != null, ct);
    }

    /// <summary>Checks step <paramref name="index"/> (0-based, in order). The last one gives the cherries and tells the
    /// parents. 422 <c>bedtime.not_open</c> outside the evening window, <c>bedtime.out_of_order</c> when skipping.</summary>
    public async Task<ChildBedtimeDto> CheckAsync(Guid familyId, Guid childId, int index, CancellationToken ct)
    {
        var tz = await db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.TimeZoneId).FirstAsync(ct);
        var routine = await db.BedtimeRoutines.AsNoTracking().FirstOrDefaultAsync(r => r.ChildId == childId && r.Enabled, ct)
                      ?? throw new NotFoundException("bedtime.not_found", "No bedtime routine.");
        var now = clock.GetUtcNow();
        var local = FamilyTimeZone.ToFamilyTime(now, tz);
        if (!routine.IsOpen(local))
        {
            throw new DomainException("bedtime.not_open", $"The routine opens at {routine.Time.Add(-BedtimeRoutine.OpensBefore):HH:mm}.");
        }

        var evening = BedtimeRoutine.EveningOf(local);
        var run = await db.BedtimeRuns.FirstOrDefaultAsync(r => r.ChildId == childId && r.Evening == evening, ct);
        var created = run is null;
        if (run is null)
        {
            run = new BedtimeRun(familyId, childId, evening, now);
            db.BedtimeRuns.Add(run);
        }

        var finished = run.Check(index, routine.Steps.Count, now);
        if (finished && routine.Cherries > 0)
        {
            db.PointEntries.Add(PointEntry.ForBedtime(familyId, childId, routine.Cherries, FamilyTimeZone.LocalDate(now, tz), now));
        }

        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (DbUpdateException) when (created)
        {
            // Two taps at once created tonight twice; the other one counted.
            db.ChangeTracker.Clear();
            return (await ChildAsync(childId, tz, ct))!;
        }

        if (finished)
        {
            await NotifyAsync(familyId, childId, run, tz, ct);
        }

        return (await ChildAsync(childId, tz, ct))!;
    }

    private async Task NotifyAsync(Guid familyId, Guid childId, BedtimeRun run, string tz, CancellationToken ct)
    {
        try
        {
            var name = await db.Children.AsNoTracking().Where(c => c.Id == childId).Select(c => c.FirstName).FirstAsync(ct);
            var at = FamilyTimeZone.ToFamilyTime(run.FinishedAt!.Value, tz).ToString("HH:mm");
            var parents = await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == familyId && m.Role != FamilyRole.Caregiver)
                .Join(db.Users.AsNoTracking(), m => m.UserId, u => u.Id, (m, u) => new { u.Id, u.Locale }).ToListAsync(ct);
            foreach (var p in parents)
            {
                var tr = p.Locale != "en";
                await publisher.AddAsync(p.Id, familyId, NotificationKind.BedtimeDone,
                    tr ? $"🌙 {name} yatağında" : $"🌙 {name} is in bed",
                    tr ? $"Uyku rutini bitti · {at}" : $"Bedtime routine done · {at}",
                    null, run.Id, $"bedtime:{run.Id:N}:{p.Id:N}", ct);
            }

            await db.SaveChangesAsync(ct);
            await publisher.FlushPushAsync(ct);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Bedtime notification failed");
        }
    }
}

/// <summary>Parents set a child's bedtime routine and see tonight's progress.</summary>
[ApiController]
[Authorize(Policy = Policies.FamilyMember)]
[Route("api/v1/families/{familyId:guid}/children/{childId:guid}/bedtime")]
public class BedtimeController(HallyDbContext db, TimeProvider clock) : ControllerBase
{
    [HttpGet]
    public async Task<BedtimeDto> Get(Guid familyId, Guid childId, CancellationToken ct)
    {
        var tz = await EnsureChild(familyId, childId, ct);
        var routine = await db.BedtimeRoutines.AsNoTracking().FirstOrDefaultAsync(r => r.ChildId == childId, ct);
        if (routine is null)
        {
            return new BedtimeDto(null, null);
        }

        var evening = BedtimeRoutine.EveningOf(FamilyTimeZone.ToFamilyTime(clock.GetUtcNow(), tz));
        var run = await db.BedtimeRuns.AsNoTracking().FirstOrDefaultAsync(r => r.ChildId == childId && r.Evening == evening, ct);
        return new BedtimeDto(ToDto(routine), run is null ? null : new BedtimeTonightDto(run.Evening, run.Done, routine.Steps.Count, run.FinishedAt));
    }

    [HttpPut]
    public async Task<BedtimeDto> Put(Guid familyId, Guid childId, BedtimeRoutineDto request, CancellationToken ct)
    {
        await EnsureChild(familyId, childId, ct);
        if (!TimeOnly.TryParse(request.Time, out var time))
        {
            throw new DomainException("bedtime.time_invalid", "Time must be HH:mm.");
        }

        var routine = await db.BedtimeRoutines.FirstOrDefaultAsync(r => r.ChildId == childId, ct);
        if (routine is null)
        {
            routine = new BedtimeRoutine(familyId, childId, clock.GetUtcNow());
            db.BedtimeRoutines.Add(routine);
        }

        routine.Update(time, (request.Steps ?? []).Select(s => new BedtimeStep(s.Title, s.Emoji)).ToList(), request.Enabled, request.LockUntilMorning, request.Cherries);
        await db.SaveChangesAsync(ct);
        return await Get(familyId, childId, ct);
    }

    private static BedtimeRoutineDto ToDto(BedtimeRoutine r) =>
        new(r.Time.ToString("HH:mm"), r.Steps.Select(s => new BedtimeStepDto(s.Title, s.Emoji)).ToList(), r.Enabled, r.LockUntilMorning, r.Cherries);

    private async Task<string> EnsureChild(Guid familyId, Guid childId, CancellationToken ct)
    {
        if (!await db.Children.AnyAsync(c => c.Id == childId && c.FamilyId == familyId, ct))
        {
            throw new NotFoundException("child.not_found", "Child not found.");
        }

        return await db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.TimeZoneId).FirstAsync(ct);
    }
}

/// <summary>The child's phone: tonight's steps and checking them off.</summary>
[ApiController]
[Authorize(Policy = ChildDeviceAuth.Policy)]
[Route("api/v1/child/bedtime")]
public class ChildBedtimeController(HallyDbContext db, BedtimeService bedtime) : ControllerBase
{
    /// <summary>204 when the child has no (enabled) routine.</summary>
    [HttpGet]
    public async Task<ActionResult<ChildBedtimeDto>> Get(CancellationToken ct)
    {
        var tz = await db.Families.AsNoTracking().Where(f => f.Id == User.ChildFamilyId()).Select(f => f.TimeZoneId).FirstAsync(ct);
        return await bedtime.ChildAsync(User.ChildId(), tz, ct) is { } dto ? dto : NoContent();
    }

    [HttpPost("steps/{index:int}/done")]
    public Task<ChildBedtimeDto> Done(int index, CancellationToken ct) => bedtime.CheckAsync(User.ChildFamilyId(), User.ChildId(), index, ct);
}
