using Hally.Api.Auth;
using Hally.Api.Common;
using Hally.Domain.Common;
using Hally.Domain.Feeding;
using Hally.Domain.Points;
using Hally.Domain.Sleep;
using Hally.Domain.Study;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.Insights;

/// <summary>One family-local day of a child's logs. Sleep counts on the day it started (days run 06:00-06:00).</summary>
public record InsightDayDto(
    DateOnly Date,
    int ScreenMinutes,
    int HomeworkMinutes,
    int ReadingMinutes,
    int NightSleepMinutes,
    int NapMinutes,
    int Feeds,
    int BottleMl,
    int BreastMinutes,
    int Solids,
    int StarsEarned,
    int StarsSpent,
    int HabitsDone,
    int HabitsScheduled,
    int Doses);

/// <param name="Done">Checked scheduled days in the range.</param>
public record HabitInsightDto(Guid Id, string Title, int Streak, int Best, int Done, int Scheduled);

public record MedicationInsightDto(Guid Id, string Name, int Doses);

public record HealthSnapshotDto(decimal? HeightCm, decimal? WeightKg, DateOnly? MeasuredOn, int VaccinesOverdue, int VaccinesDueSoon,
    string? NextAppointment, DateTimeOffset? NextAppointmentAt, bool HasAllergies);

public record ChildInsightsDto(
    Guid ChildId,
    DateOnly From,
    DateOnly To,
    DateOnly Today,
    int? ScreenGoalMinutes,
    int? StudyGoalMinutes,
    IReadOnlyList<InsightDayDto> Days,
    IReadOnlyList<HabitInsightDto> Habits,
    IReadOnlyList<MedicationInsightDto> Medications,
    int StarBalance,
    decimal ExpensesTotal,
    HealthSnapshotDto Health);

/// <summary>
/// One child's logs side by side, per family-local day: screen time, homework and reading, sleep, feeding, stars, habits and
/// medicine doses, plus the health card at a glance. Read-only; the app turns it into the day and week views.
/// </summary>
[ApiController]
[Authorize(Policy = Policies.FamilyMember)]
[CaregiverAllowed]
[Route("api/v1/families/{familyId:guid}/children/{childId:guid}/insights")]
public class InsightsController(HallyDbContext db, TimeProvider clock) : ControllerBase
{
    public const int MaxDays = 31;
    private const int HabitHistoryDays = 120;

    /// <summary><c>from</c>/<c>to</c> are inclusive family-local days; default the 7 days ending today; at most 31 days.</summary>
    [HttpGet]
    public async Task<ChildInsightsDto> Get(Guid familyId, Guid childId, [FromQuery] DateOnly? from, [FromQuery] DateOnly? to, CancellationToken ct)
    {
        var child = await db.Children.AsNoTracking().FirstOrDefaultAsync(c => c.Id == childId && c.FamilyId == familyId, ct)
                    ?? throw new NotFoundException("child.not_found", "Child not found.");
        var tz = await db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.TimeZoneId).FirstAsync(ct);
        var now = clock.GetUtcNow();
        var today = FamilyTimeZone.LocalDate(now, tz);
        var last = to ?? today;
        var first = from ?? last.AddDays(-6);
        if (first > last || last.DayNumber - first.DayNumber + 1 > MaxDays)
        {
            throw new DomainException("insights.range_invalid", $"The range must be 1-{MaxDays} days.");
        }

        var days = Enumerable.Range(0, last.DayNumber - first.DayNumber + 1).Select(first.AddDays).ToList();
        var bounds = days.Append(last.AddDays(1)).Select(d => FamilyTimeZone.StartOfDay(d, tz)).ToArray();
        var start = bounds[0];
        var end = bounds[^1];

        var screen = await db.ScreenTimeSessions.AsNoTracking()
            .Where(s => s.ChildId == childId && s.StartedAt < end && (s.EndedAt == null || s.EndedAt > start)).ToListAsync(ct);
        var study = await db.StudySessions.AsNoTracking()
            .Where(s => s.ChildId == childId && s.StartedAt < end && (s.EndedAt == null || s.EndedAt > start)).ToListAsync(ct);
        // Sleep days start at 06:00, so look a little either side and bucket by SleepDay.
        var sleep = await db.SleepEntries.AsNoTracking()
            .Where(s => s.ChildId == childId && s.StartedAt >= start.AddHours(-12) && s.StartedAt < end.AddHours(12)).ToListAsync(ct);
        var feeds = await db.FeedingEntries.AsNoTracking().Where(f => f.ChildId == childId && f.At >= start && f.At < end).ToListAsync(ct);
        var points = await db.PointEntries.AsNoTracking().Where(p => p.ChildId == childId).ToListAsync(ct);
        var doses = await db.MedicationDoses.AsNoTracking().Where(d => d.ChildId == childId && d.GivenAt >= start && d.GivenAt < end).ToListAsync(ct);
        var habits = await db.Habits.AsNoTracking().Where(h => h.ChildId == childId).OrderBy(h => h.CreatedAt).ToListAsync(ct);
        var habitIds = habits.Select(h => h.Id).ToList();
        var since = today.AddDays(-HabitHistoryDays);
        var checks = await db.HabitChecks.AsNoTracking().Where(c => habitIds.Contains(c.HabitId) && c.Day >= since).ToListAsync(ct);
        var checkedByHabit = habits.ToDictionary(h => h.Id, h => checks.Where(c => c.HabitId == h.Id).Select(c => c.Day).ToHashSet());

        int Bucket(DateTimeOffset at)
        {
            for (var i = 0; i < days.Count; i++)
            {
                if (at >= bounds[i] && at < bounds[i + 1])
                {
                    return i;
                }
            }

            return -1;
        }

        var list = new List<InsightDayDto>();
        for (var i = 0; i < days.Count; i++)
        {
            var (a, b, day) = (bounds[i], bounds[i + 1], days[i]);
            int Minutes(TimeSpan t) => (int)Math.Round(t.TotalMinutes);
            var dayFeeds = feeds.Where(f => Bucket(f.At) == i).ToList();
            var daySleep = sleep.Where(s => SleepEntry.SleepDay(s.StartedAt, tz) == day).ToList();
            var dayPoints = points.Where(p => p.Day == day).ToList();
            var scheduled = habits.Where(h => h.IsScheduled(day) && FamilyTimeZone.LocalDate(h.CreatedAt, tz) <= day).ToList();
            list.Add(new InsightDayDto(
                day,
                Minutes(screen.Aggregate(TimeSpan.Zero, (sum, s) => sum + s.Within(a, b, now))),
                Minutes(study.Where(s => s.Kind == StudyKind.Homework).Aggregate(TimeSpan.Zero, (sum, s) => sum + s.Within(a, b, now))),
                Minutes(study.Where(s => s.Kind == StudyKind.Reading).Aggregate(TimeSpan.Zero, (sum, s) => sum + s.Within(a, b, now))),
                Minutes(daySleep.Where(s => s.Kind == SleepKind.Night).Aggregate(TimeSpan.Zero, (sum, s) => sum + s.Duration(now))),
                Minutes(daySleep.Where(s => s.Kind == SleepKind.Nap).Aggregate(TimeSpan.Zero, (sum, s) => sum + s.Duration(now))),
                dayFeeds.Count,
                dayFeeds.Where(f => f.Kind == FeedingKind.Bottle).Sum(f => f.AmountMl ?? 0),
                dayFeeds.Where(f => f.Kind == FeedingKind.Breast).Sum(f => f.Minutes ?? 0),
                dayFeeds.Count(f => f.Kind == FeedingKind.Solid),
                dayPoints.Where(p => p.Kind == PointKind.Chore).Sum(p => p.Points),
                -dayPoints.Where(p => p.Kind == PointKind.Reward).Sum(p => p.Points),
                scheduled.Count(h => checkedByHabit[h.Id].Contains(day)),
                scheduled.Count,
                doses.Count(d => Bucket(d.GivenAt) == i)));
        }

        var habitDtos = habits.Select(h =>
        {
            var done = checkedByHabit[h.Id];
            var inRange = days.Where(d => h.IsScheduled(d) && FamilyTimeZone.LocalDate(h.CreatedAt, tz) <= d).ToList();
            return new HabitInsightDto(h.Id, h.Title, h.Streak(done, today, since), h.Best(done, today, since), inRange.Count(done.Contains), inRange.Count);
        }).ToList();

        var meds = await db.Medications.AsNoTracking().Where(m => m.ChildId == childId).ToListAsync(ct);
        var medDtos = meds.Where(m => m.Active || doses.Any(d => d.MedicationId == m.Id))
            .Select(m => new MedicationInsightDto(m.Id, m.Name, doses.Count(d => d.MedicationId == m.Id))).OrderByDescending(m => m.Doses).ToList();

        var access = HttpContext.Access();
        if (!access.IsParent)
        {
            // Caregivers see the day-to-day logs, not money; health only when a parent allowed it.
            return new ChildInsightsDto(childId, first, last, today, child.DailyScreenMinutes, child.DailyStudyMinutes, list, habitDtos, medDtos,
                points.Sum(p => p.Points), 0,
                access.CanSeeHealth ? await Health(childId, today, now, ct) : new HealthSnapshotDto(null, null, null, 0, 0, null, null, false));
        }

        var firstDay = days[0];
        var expenses = await db.Expenses.AsNoTracking().Where(e => e.ChildId == childId && e.Date >= firstDay && e.Date <= last).SumAsync(e => (decimal?)e.Amount, ct) ?? 0;

        return new ChildInsightsDto(childId, first, last, today, child.DailyScreenMinutes, child.DailyStudyMinutes, list, habitDtos, medDtos,
            points.Sum(p => p.Points), expenses, await Health(childId, today, now, ct));
    }

    private async Task<HealthSnapshotDto> Health(Guid childId, DateOnly today, DateTimeOffset now, CancellationToken ct)
    {
        var growth = await db.GrowthMeasurements.AsNoTracking().Where(g => g.ChildId == childId)
            .OrderByDescending(g => g.MeasuredOn).ThenByDescending(g => g.CreatedAt).Take(50).ToListAsync(ct);
        var height = growth.FirstOrDefault(g => g.HeightCm != null);
        var weight = growth.FirstOrDefault(g => g.WeightKg != null);
        var vaccines = await db.Vaccines.AsNoTracking().Where(v => v.ChildId == childId && v.GivenOn == null).Select(v => v.DueOn).ToListAsync(ct);
        var next = await db.HealthAppointments.AsNoTracking().Where(a => a.ChildId == childId)
            .Join(db.Events.AsNoTracking(), a => a.EventId, e => e.Id, (a, e) => new { e.Title, e.StartsAt })
            .Where(e => e.StartsAt >= now).OrderBy(e => e.StartsAt).FirstOrDefaultAsync(ct);
        var allergies = await db.HealthProfiles.AsNoTracking().AnyAsync(p => p.ChildId == childId && p.Allergies != null, ct);
        return new HealthSnapshotDto(height?.HeightCm, weight?.WeightKg, growth.FirstOrDefault()?.MeasuredOn,
            vaccines.Count(d => d < today), vaccines.Count(d => d >= today && d <= today.AddDays(30)), next?.Title, next?.StartsAt, allergies);
    }
}
