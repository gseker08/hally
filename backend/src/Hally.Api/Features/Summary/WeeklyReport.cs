using System.Globalization;
using Hally.Api.Auth;
using Hally.Api.Common;
using Hally.Api.Features.Events;
using Hally.Api.Features.Notifications;
using Hally.Domain.Common;
using Hally.Domain.Notifications;
using Hally.Domain.Planning;
using Hally.Domain.Points;
using Hally.Domain.School;
using Hally.Domain.ScreenTime;
using Hally.Domain.Sleep;
using Hally.Domain.Study;
using Hally.Domain.Users;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.Summary;

public record ReportAdultDto(Guid UserId, string FirstName, int Completed);

/// <param name="Outcome">Hard, Good or Great; null until a parent notes it.</param>
public record ReportExamDto(Guid Id, string Subject, DateOnly Date, string? Outcome);

/// <param name="ScreenAvgMinutes">Per day that has started in the week; null when no screen time was logged.</param>
/// <param name="SleepAvgMinutes">Night sleep; null when none was logged.</param>
/// <param name="Cherries">Earned that week (rewards and pocket money left out).</param>
public record ReportChildDto(Guid ChildId, string FirstName, string Color, IReadOnlyList<ReportExamDto> Exams, int StudyMinutes,
    int? ScreenAvgMinutes, int? SleepAvgMinutes, int Cherries, int Activities);

public record ReportUpcomingExamDto(Guid ChildId, string ChildName, string Subject, DateOnly Date);

/// <param name="BusiestDay">The day with the most events, when one has at least two.</param>
public record ReportNextWeekDto(DateOnly WeekStart, IReadOnlyList<ReportUpcomingExamDto> Exams, int Events, DateOnly? BusiestDay, int BusiestCount);

/// <param name="Offset">0 = this week, -1 = last week …</param>
/// <param name="TasksDonePrevious">The week before, for the ▲/▼ next to the count.</param>
/// <param name="Tip">One line for the coming week, or null.</param>
/// <param name="Quiet">Nothing was logged at all (no report notification goes out for such a week).</param>
public record WeeklyReportDto(int Offset, DateOnly WeekStart, DateOnly WeekEnd, int TasksDone, int TasksDonePrevious, int Events, int Exams,
    IReadOnlyList<ReportAdultDto> Adults, int HelperCompleted, IReadOnlyList<ReportChildDto> Children, ReportNextWeekDto NextWeek, string? Tip, bool Quiet);

/// <summary>
/// "Haftanın özeti": the family's week (Monday-Sunday, family time zone) in one place, and the Sunday-evening (or
/// Monday-morning) notification that opens it. Built from the family's own data, no AI. Parents only.
/// </summary>
public class WeeklyReportService(HallyDbContext db, NotificationPublisher publisher, TimeProvider clock, ILogger<WeeklyReportService> logger)
{
    public const int MaxBack = 8;

    /// <summary>The week a report opened today shows by default: on Monday the one that just ended.</summary>
    public int DefaultOffset(DateOnly today) => today.DayOfWeek == DayOfWeek.Monday ? -1 : 0;

    public async Task<WeeklyReportDto> BuildAsync(Guid familyId, int? offset, string? lang, CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        var family = await db.Families.AsNoTracking().Include(f => f.Members).Include(f => f.Children).FirstAsync(f => f.Id == familyId, ct);
        var tz = family.TimeZoneId;
        var today = FamilyTimeZone.LocalDate(now, tz);
        var week = Math.Clamp(offset ?? DefaultOffset(today), -MaxBack, 0);
        var monday = today.AddDays(-(((int)today.DayOfWeek + 6) % 7) + 7 * week);
        var sunday = monday.AddDays(6);
        DateTimeOffset At(DateOnly d) => FamilyTimeZone.StartOfDay(d, tz);
        var (start, end) = (At(monday), At(monday.AddDays(7)));

        var previous = At(monday.AddDays(-7));
        var done = await db.Tasks.AsNoTracking()
            .Where(t => t.FamilyId == familyId && t.State == TaskState.Done && t.CompletedAt >= previous && t.CompletedAt < end)
            .Select(t => new { t.CompletedAt, t.CompletedByUserId, t.CompletedByHelper }).ToListAsync(ct);
        var thisWeek = done.Where(t => t.CompletedAt >= start).ToList();
        var events = (await db.EventsInRangeAsync(familyId, start, end, tz, ct)).Where(e => e.StartsAt >= start).ToList();

        var parents = family.Members.Where(m => m.IsParent).Select(m => m.UserId).ToList();
        var names = await db.Users.AsNoTracking().Where(u => parents.Contains(u.Id)).ToDictionaryAsync(u => u.Id, u => u.DisplayName, ct);
        var adults = parents.Select(id => new ReportAdultDto(id, FirstName(names.GetValueOrDefault(id, "")), thisWeek.Count(t => t.CompletedByUserId == id)))
            .OrderByDescending(a => a.Completed).ToList();

        var children = family.Children.OrderBy(c => c.CreatedAt).ToList();
        var childIds = children.Select(c => c.Id).ToList();
        var exams = await db.Exams.AsNoTracking()
            .Where(e => e.FamilyId == familyId && e.Date >= monday && e.Date <= sunday.AddDays(7)).OrderBy(e => e.Date).ToListAsync(ct);
        var (studyFrom, screenFrom) = (start - StudySession.MaxLength, start - ScreenTimeSession.MaxLength);
        var study = await db.StudySessions.AsNoTracking()
            .Where(s => s.FamilyId == familyId && s.StartedAt >= studyFrom && s.StartedAt < end).ToListAsync(ct);
        var screen = await db.ScreenTimeSessions.AsNoTracking()
            .Where(s => s.FamilyId == familyId && s.StartedAt >= screenFrom && s.StartedAt < end).ToListAsync(ct);
        var sleep = await db.SleepEntries.AsNoTracking()
            .Where(s => s.FamilyId == familyId && s.Kind == SleepKind.Night && s.EndedAt != null && s.EndedAt >= start && s.EndedAt < end).ToListAsync(ct);
        var points = await db.PointEntries.AsNoTracking()
            .Where(p => p.FamilyId == familyId && p.Day >= monday && p.Day <= sunday).ToListAsync(ct);

        var daysElapsed = Math.Clamp(today.DayNumber - monday.DayNumber + 1, 1, 7);
        var rows = new List<ReportChildDto>();
        foreach (var c in children)
        {
            var mine = screen.Where(s => s.ChildId == c.Id).ToList();
            var screenSeconds = mine.Aggregate(TimeSpan.Zero, (sum, s) => sum + s.Within(start, end, now)).TotalSeconds;
            var nights = sleep.Where(s => s.ChildId == c.Id).ToList();
            var studySeconds = study.Where(s => s.ChildId == c.Id)
                .Sum(s => Math.Max(0, ((s.CountsUntil(now) < end ? s.CountsUntil(now) : end) - (s.StartedAt > start ? s.StartedAt : start)).TotalSeconds));
            var earned = points.Where(p => p.ChildId == c.Id && p.Points > 0 && p.Kind != PointKind.Allowance && p.Kind != PointKind.Reward).ToList();
            rows.Add(new ReportChildDto(c.Id, c.FirstName, c.Color,
                exams.Where(e => e.ChildId == c.Id && e.Date <= sunday).Select(e => new ReportExamDto(e.Id, e.Subject, e.Date, e.Outcome?.ToString())).ToList(),
                (int)(studySeconds / 60),
                mine.Count == 0 ? null : (int)(screenSeconds / 60 / daysElapsed),
                nights.Count == 0 ? null : (int)nights.Average(n => (n.EndedAt!.Value - n.StartedAt).TotalMinutes),
                earned.Sum(p => p.Points),
                earned.Count(p => p.Kind == PointKind.Activity)));
        }

        // The week after: exams, event count and the busiest day.
        var nextMonday = monday.AddDays(7);
        var nextEvents = (await db.EventsInRangeAsync(familyId, At(nextMonday), At(nextMonday.AddDays(7)), tz, ct)).Where(e => e.StartsAt >= At(nextMonday)).ToList();
        var nextExams = exams.Where(e => e.Date >= nextMonday)
            .Select(e => new ReportUpcomingExamDto(e.ChildId, children.FirstOrDefault(c => c.Id == e.ChildId)?.FirstName ?? "", e.Subject, e.Date)).ToList();
        var busiest = nextEvents.GroupBy(e => FamilyTimeZone.LocalDate(e.StartsAt, tz)).OrderByDescending(g => g.Count()).ThenBy(g => g.Key).FirstOrDefault();
        var next = new ReportNextWeekDto(nextMonday, nextExams, nextEvents.Count,
            busiest is { } b && b.Count() >= 2 ? b.Key : null, busiest is { } bb && bb.Count() >= 2 ? bb.Count() : 0);

        var culture = Texts.Culture(lang);
        string? tip = null;
        if (nextExams.GroupBy(e => e.ChildId).FirstOrDefault(g => g.Count() >= 2) is { } heavy)
        {
            var who = heavy.First().ChildName;
            tip = Texts.Get(lang, "report.tip.exams", ("name", who), ("count", heavy.Count()));
        }
        else if (next.BusiestDay is { } day && next.BusiestCount >= 3)
        {
            var name = culture.DateTimeFormat.GetDayName(day.DayOfWeek);
            tip = Texts.Get(lang, "report.tip.busy", ("day", name), ("count", next.BusiestCount));
        }

        var weekExams = exams.Count(e => e.Date <= sunday);
        var quiet = thisWeek.Count == 0 && events.Count == 0 && weekExams == 0
                    && rows.All(r => r.StudyMinutes == 0 && r.ScreenAvgMinutes is null && r.SleepAvgMinutes is null && r.Cherries == 0);
        return new WeeklyReportDto(week, monday, sunday, thisWeek.Count, done.Count - thisWeek.Count, events.Count, weekExams,
            adults, thisWeek.Count(t => t.CompletedByHelper), rows, next, tip, quiet);
    }

    /// <summary>The notification body: a few counts, most telling first.</summary>
    public static string Body(WeeklyReportDto r, string? lang)
    {
        var parts = new List<string>();
        if (r.TasksDone > 0 || r.Events > 0)
        {
            parts.Add(Texts.Get(lang, "report.body.week", ("tasks", r.TasksDone), ("events", r.Events)));
        }

        foreach (var c in r.Children.Where(c => c.Exams.Count > 0).Take(2))
        {
            parts.Add(Texts.Plural(lang, "report.body.childExams", c.Exams.Count, ("name", c.FirstName)));
        }

        var cherries = r.Children.Sum(c => c.Cherries);
        if (cherries > 0)
        {
            parts.Add(Texts.Get(lang, "report.body.cherries", ("count", cherries)));
        }

        if (r.NextWeek.Exams.Count > 0)
        {
            parts.Add(Texts.Plural(lang, "report.body.nextExams", r.NextWeek.Exams.Count));
        }

        return parts.Count == 0 ? Texts.Get(lang, "report.body.empty") : string.Join(" ", parts);
    }

    /// <summary>Hangfire, every 15 minutes: the weekly report for each parent whose day and time has come.</summary>
    public async Task<int> WeeklyAsync(CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        var members = await db.FamilyMembers.Where(m => m.WeeklyReportTime != null && m.Role != Hally.Domain.Families.FamilyRole.Caregiver).ToListAsync(ct);
        var familyIds = members.Select(m => m.FamilyId).Distinct().ToList();
        var zones = await db.Families.AsNoTracking().Where(f => familyIds.Contains(f.Id)).ToDictionaryAsync(f => f.Id, f => f.TimeZoneId, ct);
        var due = members.Where(m => m.TakeWeeklyReport(FamilyTimeZone.ToFamilyTime(now, zones[m.FamilyId]).DateTime)).ToList();
        if (due.Count == 0)
        {
            return 0;
        }

        await db.SaveChangesAsync(ct);
        var sent = 0;
        foreach (var m in due)
        {
            try
            {
                var lang = Locales.Normalize(await db.Users.AsNoTracking().Where(u => u.Id == m.UserId).Select(u => u.Locale).FirstAsync(ct));
                var report = await BuildAsync(m.FamilyId, null, lang, ct);
                if (report.Quiet)
                {
                    continue;
                }

                if (await publisher.AddAsync(m.UserId, m.FamilyId, NotificationKind.WeeklyReport,
                        Texts.Get(lang, "report.push.title"), Body(report, lang), null, null,
                        $"weekly:{m.UserId:N}:{m.FamilyId:N}:{report.WeekStart:yyyyMMdd}", ct))
                {
                    sent++;
                }
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogWarning(ex, "Weekly report failed");
            }
        }

        await db.SaveChangesAsync(ct);
        await publisher.FlushPushAsync(ct);
        return sent;
    }

    private static string FirstName(string displayName) => displayName.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "";
}

[ApiController]
[Authorize(Policy = Policies.FamilyMember)]
[Route("api/v1/families/{familyId:guid}/weekly-report")]
public class WeeklyReportController(HallyDbContext db, WeeklyReportService reports) : ControllerBase
{
    /// <param name="offset">0 = this week, -1 = last week (default: last week on Mondays, else this week).</param>
    [HttpGet]
    public async Task<WeeklyReportDto> Get(Guid familyId, [FromQuery] int? offset, CancellationToken ct)
    {
        var userId = User.UserId();
        var locale = await db.Users.AsNoTracking().Where(u => u.Id == userId).Select(u => u.Locale).FirstAsync(ct);
        return await reports.BuildAsync(familyId, offset, Locales.Normalize(locale), ct);
    }
}
