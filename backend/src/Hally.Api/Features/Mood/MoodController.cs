using Hally.Api.Auth;
using Hally.Api.Common;
using Hally.Domain.Common;
using Hally.Domain.Mood;
using Hally.Domain.Points;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.Mood;

/// <param name="Mood">Great, Good, Okay, Sad, Angry or Tired.</param>
/// <param name="Reasons">Friends, School, Home, Play (optional).</param>
public record MoodRequest(string Mood, IReadOnlyList<string>? Reasons);

/// <param name="Cherries">1 the first time today, 0 when the answer was only changed.</param>
public record MoodAnswerDto(string Mood, int Cherries);

/// <param name="Mood">Null on a day without an answer.</param>
public record MoodDayDto(DateOnly Date, string? Mood, IReadOnlyList<string> Reasons);

/// <summary>A gentle suggestion after a hard day (sad or angry) in the last <see cref="MoodController.NudgeDays"/> days.</summary>
public record MoodNudgeDto(DateOnly Date, string Mood, string? Reason);

public record MoodWeekDto(DateOnly From, DateOnly To, DateOnly Today, IReadOnlyList<MoodDayDto> Days, string? MostCommon, int MostCommonDays,
    string? TopReason, MoodNudgeDto? Nudge);

/// <summary>"Bugün nasılsın?" from the child's phone: one answer a day, one cherry whatever the answer.</summary>
[ApiController]
[Authorize(Policy = ChildDeviceAuth.Policy)]
[Route("api/v1/child/mood")]
public class ChildMoodController(HallyDbContext db, TimeProvider clock) : ControllerBase
{
    [HttpPost]
    public async Task<MoodAnswerDto> Answer(MoodRequest request, CancellationToken ct)
    {
        var (familyId, childId) = (User.ChildFamilyId(), User.ChildId());
        var mood = Parse<Domain.Mood.Mood>(request.Mood, "mood.invalid");
        var reasons = (request.Reasons ?? []).Select(r => Parse<MoodReason>(r, "mood.reason_invalid")).ToList();
        var tz = await db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.TimeZoneId).FirstAsync(ct);
        var now = clock.GetUtcNow();
        var today = FamilyTimeZone.LocalDate(now, tz);

        var check = await db.MoodChecks.FirstOrDefaultAsync(m => m.ChildId == childId && m.Day == today, ct);
        var first = check is null;
        if (check is null)
        {
            check = new MoodCheck(familyId, childId, today, now);
            db.MoodChecks.Add(check);
        }

        check.Answer(mood, reasons);
        var cherries = 0;
        if (first && !await db.PointEntries.AnyAsync(p => p.ChildId == childId && p.Kind == PointKind.Mood && p.Day == today, ct))
        {
            db.PointEntries.Add(PointEntry.ForMood(familyId, childId, today, now));
            cherries = 1;
        }

        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (DbUpdateException) when (first)
        {
            // Two taps at once: the other request already saved today's answer and cherry.
            return new MoodAnswerDto(mood.ToString(), 0);
        }

        return new MoodAnswerDto(mood.ToString(), cherries);
    }

    internal static T Parse<T>(string? raw, string code) where T : struct, Enum =>
        Enum.TryParse<T>(raw, true, out var v) && Enum.IsDefined(v) ? v : throw new DomainException(code, $"Unknown value '{raw}'.");
}

/// <summary>
/// Parents' view of a child's moods ("Duygular"): the answers per day, the most common one, the usual reason and a gentle
/// nudge after a hard day. Parents only: caregivers never see it. Answers older than 90 days are deleted.
/// </summary>
[ApiController]
[Authorize(Policy = Policies.FamilyMember)]
[Route("api/v1/families/{familyId:guid}/children/{childId:guid}/moods")]
public class MoodController(HallyDbContext db, TimeProvider clock) : ControllerBase
{
    public const int MaxDays = 28;
    public const int NudgeDays = 3;

    /// <summary><c>from</c>/<c>to</c> inclusive family-local days; default the 7 days ending today; at most 28.</summary>
    [HttpGet]
    public async Task<MoodWeekDto> Get(Guid familyId, Guid childId, [FromQuery] DateOnly? from, [FromQuery] DateOnly? to, CancellationToken ct)
    {
        if (!await db.Children.AnyAsync(c => c.Id == childId && c.FamilyId == familyId, ct))
        {
            throw new NotFoundException("child.not_found", "Child not found.");
        }

        var tz = await db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.TimeZoneId).FirstAsync(ct);
        var today = FamilyTimeZone.LocalDate(clock.GetUtcNow(), tz);
        var last = to ?? today;
        var first = from ?? last.AddDays(-6);
        if (first > last || last.DayNumber - first.DayNumber + 1 > MaxDays)
        {
            throw new DomainException("mood.range_invalid", $"The range must be 1-{MaxDays} days.");
        }

        var checks = await db.MoodChecks.AsNoTracking().Where(m => m.ChildId == childId && m.Day >= first && m.Day <= last).ToListAsync(ct);
        var byDay = checks.ToDictionary(m => m.Day);
        var days = Enumerable.Range(0, last.DayNumber - first.DayNumber + 1).Select(first.AddDays)
            .Select(d => byDay.TryGetValue(d, out var m)
                ? new MoodDayDto(d, m.Mood.ToString(), m.Reasons.Select(r => r.ToString()).ToList())
                : new MoodDayDto(d, null, []))
            .ToList();

        var common = checks.GroupBy(m => m.Mood).OrderByDescending(g => g.Count()).ThenBy(g => g.Key).FirstOrDefault();
        var reason = checks.SelectMany(m => m.Reasons).GroupBy(r => r).OrderByDescending(g => g.Count()).ThenBy(g => g.Key).FirstOrDefault();
        var hard = checks.Where(m => MoodCheck.IsHard(m.Mood) && m.Day > today.AddDays(-NudgeDays) && m.Day <= today).OrderByDescending(m => m.Day).FirstOrDefault();

        return new MoodWeekDto(first, last, today, days, common?.Key.ToString(), common?.Count() ?? 0, reason?.Key.ToString(),
            hard is null ? null : new MoodNudgeDto(hard.Day, hard.Mood.ToString(), hard.Reasons.Count > 0 ? hard.Reasons[0].ToString() : null));
    }
}
