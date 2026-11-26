using System.Globalization;
using FluentValidation;
using Hally.Api.Auth;
using Hally.Api.Common;
using Hally.Api.Features.Events;
using Hally.Domain.Common;
using Hally.Domain.Families;
using Hally.Domain.Planning;
using Hally.Domain.Points;
using Hally.Domain.Sleep;
using Hally.Domain.Tips;
using Hally.Domain.Users;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.Tips;

/// <summary>One "Hally fark etti" line on Today.</summary>
/// <param name="Key">Names the situation; dismissing hides this key only.</param>
/// <param name="Kind">ExamScreen, ExamStudy, Vaccine, Sleep, Overdue or Weekend.</param>
/// <param name="Action">screenLimit (sheet), bedtimeEarlier, startStudy or route.</param>
/// <param name="Minutes">screenLimit: the suggested daily limit; bedtimeEarlier: how much earlier.</param>
/// <param name="CurrentMinutes">screenLimit: today's limit (null = none).</param>
/// <param name="RestoreOn">screenLimit: the day after the last exam, when the old limit comes back.</param>
/// <param name="Detail">A second line for the sheet ("Sınavlar: Perşembe Matematik, Cuma Fen").</param>
public record TipDto(string Key, string Kind, string Emoji, string Text, string ActionLabel, string Action,
    Guid? ChildId = null, Guid? ExamId = null, int? Minutes = null, int? CurrentMinutes = null, DateOnly? RestoreOn = null,
    string? Route = null, string? Detail = null);

/// <param name="Forever">true = "✕" (never again), false = "Sonra" (back tomorrow).</param>
public record DismissTipRequest(string Key, bool Forever);

/// <param name="Hidden">Tips hidden for good with ✕ ("Geri getir" brings them back).</param>
/// <param name="ReportDay">Sunday or Monday.</param>
/// <param name="ReportTime">"HH:mm", or null when the weekly report notification is off.</param>
public record TipSettingsDto(bool Enabled, int Hidden, string ReportDay, string? ReportTime, bool CanGetReport);

public record TipSettingsRequest(bool Enabled, string? ReportDay, string? ReportTime);

/// <param name="RestoreOn">null keeps the new limit; a day puts the old one back then ("Sınavlar bitince geri al").</param>
public record TipScreenLimitRequest(Guid ChildId, int Minutes, DateOnly? RestoreOn);

public record TipBedtimeRequest(Guid ChildId, int Minutes);

public class TipScreenLimitRequestValidator : AbstractValidator<TipScreenLimitRequest>
{
    public TipScreenLimitRequestValidator() => RuleFor(x => x.Minutes).InclusiveBetween(Child.MinScreenGoal, Child.MaxScreenGoal);
}

public class TipBedtimeRequestValidator : AbstractValidator<TipBedtimeRequest>
{
    public TipBedtimeRequestValidator() => RuleFor(x => x.Minutes).InclusiveBetween(5, 60);
}

/// <summary>
/// "Akıllı ipuçları": short, rule-based suggestions worked out from what the family already keeps in Hally (exams,
/// screen time, sleep, tasks, the calendar, vaccines). No AI, nothing stored but the member's dismissals. Only the
/// member's focus areas (setup wizard) count, a caregiver only sees their own children and health only with permission,
/// and tips that change a parent's settings are for parents.
/// </summary>
public class TipsService(HallyDbContext db, TimeProvider clock)
{
    public const int MaxTips = 3;

    /// <summary>The limit an exam week suggests.</summary>
    public const int ExamWeekScreenMinutes = 60;

    /// <summary>How much earlier the bedtime routine moves when sleep runs short.</summary>
    public const int BedtimeShiftMinutes = 20;

    public async Task<IReadOnlyList<TipDto>> ListAsync(Guid familyId, Guid userId, CancellationToken ct)
    {
        var member = await db.FamilyMembers.AsNoTracking().FirstAsync(m => m.FamilyId == familyId && m.UserId == userId, ct);
        if (!member.TipsEnabled)
        {
            return [];
        }

        var now = clock.GetUtcNow();
        var family = await db.Families.AsNoTracking().Include(f => f.Children).Include(f => f.Members).FirstAsync(f => f.Id == familyId, ct);
        var tz = family.TimeZoneId;
        var today = FamilyTimeZone.LocalDate(now, tz);
        var lang = Locales.Normalize(await db.Users.AsNoTracking().Where(u => u.Id == userId).Select(u => u.Locale).FirstAsync(ct));
        var culture = Texts.Culture(lang);
        string T(string key, params (string Name, object? Value)[] args) => Texts.Get(lang, key, args);
        string When(DateOnly d) => d == today.AddDays(1) ? T("tip.tomorrow") : T("tip.onDay", ("day", culture.DateTimeFormat.GetDayName(d.DayOfWeek)));

        var parent = member.IsParent;
        var scope = parent || member.ChildIds.Count == 0 ? null : member.ChildIds.ToHashSet();
        var children = family.Children.Where(c => scope?.Contains(c.Id) ?? true).OrderBy(c => c.CreatedAt).ToList();
        var areas = member.FocusAreas.ToHashSet();
        bool Wants(params string[] any) => areas.Count == 0 || any.Any(areas.Contains);

        var tips = new List<TipDto>();
        var childIds = children.Select(c => c.Id).ToList();

        // Exams in the next seven days: study first, then screen time.
        if (Wants(FocusArea.School, FocusArea.ScreenTime) && childIds.Count > 0)
        {
            var exams = await db.Exams.AsNoTracking()
                .Where(e => e.FamilyId == familyId && childIds.Contains(e.ChildId) && e.Date >= today && e.Date <= today.AddDays(6) && e.Outcome == null)
                .OrderBy(e => e.Date).ToListAsync(ct);
            var examIds = exams.Select(e => e.Id).ToList();
            var studied = await db.StudySessions.AsNoTracking().Where(s => s.ExamId != null && examIds.Contains(s.ExamId.Value))
                .Select(s => s.ExamId!.Value).Distinct().ToListAsync(ct);

            if (Wants(FocusArea.School))
            {
                foreach (var exam in exams.Where(e => e.Date > today && e.Date <= today.AddDays(3) && !studied.Contains(e.Id)))
                {
                    var child = children.First(c => c.Id == exam.ChildId);
                    tips.Add(new TipDto($"exam-study:{exam.Id:N}", "ExamStudy", "📚",
                        T("tip.examStudy.text", ("name", child.FirstName), ("when", When(exam.Date)), ("subject", exam.Subject)),
                        T("tip.examStudy.action"), "startStudy", child.Id, exam.Id));
                }
            }

            if (parent && Wants(FocusArea.School, FocusArea.ScreenTime))
            {
                foreach (var group in exams.GroupBy(e => e.ChildId).Where(g => g.Count() >= 2))
                {
                    var child = children.First(c => c.Id == group.Key);
                    if (child.DailyScreenMinutes is { } goal && goal <= ExamWeekScreenMinutes)
                    {
                        continue;
                    }

                    var list = group.ToList();
                    var sunday = today.AddDays(6 - ((int)today.DayOfWeek + 6) % 7);
                    var when = list[^1].Date <= sunday ? T("tip.thisWeek") : T("tip.comingDays");
                    var detail = T("tip.examScreen.detail", ("exams", string.Join(", ", list.Select(e => $"{culture.DateTimeFormat.GetDayName(e.Date.DayOfWeek)} {e.Subject}"))));
                    tips.Add(new TipDto($"exam-screen:{child.Id:N}:{list[0].Date:yyyyMMdd}", "ExamScreen", "📝",
                        T("tip.examScreen.text", ("name", child.FirstName), ("count", list.Count), ("when", when)),
                        T("tip.examScreen.action", ("minutes", ExamWeekScreenMinutes)), "screenLimit", child.Id,
                        Minutes: ExamWeekScreenMinutes, CurrentMinutes: child.DailyScreenMinutes, RestoreOn: list[^1].Date.AddDays(1), Detail: detail));
                }
            }
        }

        // Vaccines due within a week that are not on the calendar that day.
        if (Wants(FocusArea.Health, FocusArea.Baby) && (parent || member.CanSeeHealth) && childIds.Count > 0)
        {
            var due = await db.Vaccines.AsNoTracking()
                .Where(v => v.FamilyId == familyId && childIds.Contains(v.ChildId) && v.GivenOn == null && v.DueOn != null && v.DueOn >= today && v.DueOn <= today.AddDays(7))
                .OrderBy(v => v.DueOn).ToListAsync(ct);
            foreach (var v in due)
            {
                var day = v.DueOn!.Value;
                var events = await db.EventsInRangeAsync(familyId, FamilyTimeZone.StartOfDay(day, tz), FamilyTimeZone.StartOfDay(day.AddDays(1), tz), tz, ct);
                if (events.Any(e => e.ChildIds.Contains(v.ChildId) || e.ChildIds.Count == 0))
                {
                    continue;
                }

                var child = children.First(c => c.Id == v.ChildId);
                var days = day.DayNumber - today.DayNumber;
                var whenText = days switch
                {
                    0 => T("tip.today"),
                    1 => T("tip.tomorrow"),
                    _ => T("tip.inDays", ("days", days)),
                };
                tips.Add(new TipDto($"vaccine:{v.Id:N}", "Vaccine", "💉",
                    T("tip.vaccine.text", ("name", child.FirstName), ("vaccine", v.Name), ("when", whenText)),
                    T("tip.vaccine.action"), "route", child.Id, Route: "/health"));
            }
        }

        // Sleep: the last three nights averaged well under what the child's age needs.
        if (Wants(FocusArea.Baby, FocusArea.Routines) && childIds.Count > 0)
        {
            var since = now.AddDays(-4);
            var nights = await db.SleepEntries.AsNoTracking()
                .Where(s => childIds.Contains(s.ChildId) && s.Kind == SleepKind.Night && s.EndedAt != null && s.EndedAt >= since)
                .ToListAsync(ct);
            foreach (var child in children)
            {
                var last = nights.Where(n => n.ChildId == child.Id).OrderByDescending(n => n.EndedAt).Take(3).ToList();
                if (last.Count < 3)
                {
                    continue;
                }

                var avg = (int)last.Average(n => (n.EndedAt!.Value - n.StartedAt).TotalMinutes);
                var need = RecommendedSleepMinutes(child.BirthYear, today.Year);
                if (avg >= need - 30)
                {
                    continue;
                }

                var routine = parent ? await db.BedtimeRoutines.AsNoTracking().FirstOrDefaultAsync(r => r.ChildId == child.Id && r.Enabled, ct) : null;
                var text = T("tip.sleep.text", ("name", child.FirstName), ("average", Duration(avg, lang)), ("need", Duration(need, lang)));
                var key = $"sleep:{child.Id:N}:{today.AddDays(-((int)today.DayOfWeek + 6) % 7):yyyyMMdd}";
                tips.Add(routine is null
                    ? new TipDto(key, "Sleep", "😴", text, T("tip.sleep.action"), "route", child.Id, Route: "/sleep")
                    : new TipDto(key, "Sleep", "😴", text, T("tip.sleep.earlier", ("minutes", BedtimeShiftMinutes)),
                        "bedtimeEarlier", child.Id, Minutes: BedtimeShiftMinutes, Detail: routine.Time.ToString("HH:mm", CultureInfo.InvariantCulture)));
            }
        }

        // Three or more tasks past due.
        if (Wants(FocusArea.Tasks, FocusArea.Teamwork))
        {
            var start = FamilyTimeZone.StartOfDay(today, tz);
            var overdue = (await db.Tasks.AsNoTracking()
                    .Where(t => t.FamilyId == familyId && t.State == TaskState.Open && t.DueAt != null && t.DueAt < start).ToListAsync(ct))
                .Where(t => scope is null || t.ChildIds.Count == 0 || t.ChildIds.Any(scope.Contains)).ToList();
            if (overdue.Count >= 3)
            {
                var others = family.Members.Where(m => m.IsParent && m.UserId != userId).Select(m => m.UserId).ToList();
                var other = parent && others.Count == 1
                    ? (await db.Users.AsNoTracking().Where(u => u.Id == others[0]).Select(u => u.DisplayName).FirstOrDefaultAsync(ct))?.Split(' ')[0]
                    : null;
                tips.Add(new TipDto($"overdue:{today.AddDays(-((int)today.DayOfWeek + 6) % 7):yyyyMMdd}", "Overdue", "✅",
                    other is null
                        ? T("tip.overdue.text", ("count", overdue.Count))
                        : T("tip.overdue.other", ("count", overdue.Count), ("name", other)),
                    T("tip.overdue.action"), "route", Route: "/tasks"));
            }
        }

        // Thursday to Saturday morning, with nothing on the weekend's calendar.
        if (parent && Wants(FocusArea.Cherries, FocusArea.Routines, FocusArea.Teamwork) && children.Count > 0
            && today.DayOfWeek is DayOfWeek.Thursday or DayOfWeek.Friday or DayOfWeek.Saturday)
        {
            var saturday = today.AddDays(DayOfWeek.Saturday - today.DayOfWeek);
            var events = await db.EventsInRangeAsync(familyId, FamilyTimeZone.StartOfDay(saturday, tz), FamilyTimeZone.StartOfDay(saturday.AddDays(2), tz), tz, ct);
            if (events.Count == 0)
            {
                tips.Add(new TipDto($"weekend:{saturday:yyyyMMdd}", "Weekend", "🌳",
                    T("tip.weekend.text"),
                    T("tip.weekend.action"), "route", Route: $"/activities?familyId={familyId}"));
            }
        }

        if (tips.Count == 0)
        {
            return [];
        }

        var keys = tips.Select(t => t.Key).ToList();
        var hidden = await db.TipDismissals.AsNoTracking().Where(d => d.UserId == userId && d.FamilyId == familyId && keys.Contains(d.Key)).ToListAsync(ct);
        return tips.Where(t => !hidden.Any(h => h.Key == t.Key && h.Hides(today))).Take(MaxTips).ToList();
    }

    public async Task DismissAsync(Guid familyId, Guid userId, DismissTipRequest request, CancellationToken ct)
    {
        var tz = await db.FamilyTimeZoneAsync(familyId, ct);
        var now = clock.GetUtcNow();
        DateOnly? until = request.Forever ? null : FamilyTimeZone.LocalDate(now, tz).AddDays(1);
        var row = await db.TipDismissals.FirstOrDefaultAsync(d => d.UserId == userId && d.FamilyId == familyId && d.Key == request.Key, ct);
        if (row is null)
        {
            db.TipDismissals.Add(new TipDismissal(familyId, userId, request.Key, until, now));
        }
        else
        {
            row.Set(until, now);
        }

        await db.SaveChangesAsync(ct);
    }

    /// <summary>Hourly: limits lowered for an exam week go back once the exams are over.</summary>
    public async Task<int> RestoreScreenGoalsAsync(CancellationToken ct)
    {
        var pending = await db.Children.Where(c => c.ScreenGoalRestoreOn != null).ToListAsync(ct);
        if (pending.Count == 0)
        {
            return 0;
        }

        var familyIds = pending.Select(c => c.FamilyId).Distinct().ToList();
        var zones = await db.Families.AsNoTracking().Where(f => familyIds.Contains(f.Id)).ToDictionaryAsync(f => f.Id, f => f.TimeZoneId, ct);
        var now = clock.GetUtcNow();
        var changed = pending.Count(c => c.RestoreScreenTimeGoal(FamilyTimeZone.LocalDate(now, zones[c.FamilyId])));
        await db.SaveChangesAsync(ct);
        return changed;
    }

    /// <summary>Rough nightly sleep advised by age (AASM ranges, lower middle); 9 hours when the age is unknown.</summary>
    public static int RecommendedSleepMinutes(int? birthYear, int year) => (birthYear is { } y ? year - y : 8) switch
    {
        <= 2 => 11 * 60,
        <= 5 => 10 * 60,
        <= 12 => 9 * 60 + 30,
        _ => 8 * 60 + 30,
    };

    private static string Duration(int minutes, string lang) => Hally.Api.Features.ScreenTime.ScreenTimeTexts.Duration(lang, minutes);
}

[ApiController]
[Authorize(Policy = Policies.FamilyMember)]
[Route("api/v1/families/{familyId:guid}/tips")]
public class TipsController(HallyDbContext db, TipsService tips, TimeProvider clock) : ControllerBase
{
    [HttpGet]
    [CaregiverAllowed]
    public Task<IReadOnlyList<TipDto>> Get(Guid familyId, CancellationToken ct) => tips.ListAsync(familyId, User.UserId(), ct);

    [HttpPost("dismiss")]
    [CaregiverAllowed]
    public async Task<IActionResult> Dismiss(Guid familyId, DismissTipRequest request, CancellationToken ct)
    {
        await tips.DismissAsync(familyId, User.UserId(), request, ct);
        return NoContent();
    }

    /// <summary>"Geri getir": every tip hidden with ✕ may show again.</summary>
    [HttpDelete("dismissed")]
    [CaregiverAllowed]
    public async Task<TipSettingsDto> Restore(Guid familyId, CancellationToken ct)
    {
        var userId = User.UserId();
        await db.TipDismissals.Where(d => d.UserId == userId && d.FamilyId == familyId).ExecuteDeleteAsync(ct);
        return await Settings(familyId, ct);
    }

    [HttpGet("settings")]
    [CaregiverAllowed]
    public async Task<TipSettingsDto> Settings(Guid familyId, CancellationToken ct)
    {
        var userId = User.UserId();
        var m = await db.FamilyMembers.AsNoTracking().FirstAsync(x => x.FamilyId == familyId && x.UserId == userId, ct);
        var hidden = await db.TipDismissals.CountAsync(d => d.UserId == userId && d.FamilyId == familyId && d.Until == null, ct);
        return new TipSettingsDto(m.TipsEnabled, hidden, m.WeeklyReportDay.ToString(),
            m.IsParent ? m.WeeklyReportTime?.ToString("HH:mm", CultureInfo.InvariantCulture) : null, m.IsParent);
    }

    /// <summary>Tips on/off for everyone; the weekly report time only for parents (caregivers never get it).</summary>
    [HttpPut("settings")]
    [CaregiverAllowed]
    public async Task<TipSettingsDto> SetSettings(Guid familyId, TipSettingsRequest request, CancellationToken ct)
    {
        var userId = User.UserId();
        var m = await db.FamilyMembers.FirstAsync(x => x.FamilyId == familyId && x.UserId == userId, ct);
        m.SetTipsEnabled(request.Enabled);
        if (m.IsParent)
        {
            if (!Enum.TryParse<DayOfWeek>(request.ReportDay ?? nameof(DayOfWeek.Sunday), true, out var day))
            {
                throw new DomainException("weekly_report.day_invalid", "The weekly report comes on Sunday or Monday.");
            }

            TimeOnly? time = null;
            if (!string.IsNullOrWhiteSpace(request.ReportTime))
            {
                if (!TimeOnly.TryParseExact(request.ReportTime, "HH:mm", CultureInfo.InvariantCulture, DateTimeStyles.None, out var t))
                {
                    throw new DomainException("weekly_report.time_invalid", "Time must be HH:mm.");
                }

                time = t;
            }

            m.SetWeeklyReport(day, time);
        }

        await db.SaveChangesAsync(ct);
        return await Settings(familyId, ct);
    }

    /// <summary>"Limiti 60 dk yap": sets the child's daily screen goal, optionally only until the exams are over.</summary>
    [HttpPost("screen-limit")]
    public async Task<IActionResult> ScreenLimit(Guid familyId, TipScreenLimitRequest request, CancellationToken ct)
    {
        var child = await db.Children.FirstOrDefaultAsync(c => c.FamilyId == familyId && c.Id == request.ChildId, ct)
                    ?? throw new NotFoundException("child.not_found", "Child not found.");
        var today = FamilyTimeZone.LocalDate(clock.GetUtcNow(), await db.FamilyTimeZoneAsync(familyId, ct));
        if (request.RestoreOn is { } day && (day <= today || day > today.AddDays(30)))
        {
            throw new DomainException("tip.restore_invalid", "The old limit can come back within 30 days.");
        }

        child.LowerScreenTimeGoalUntil(request.Minutes, request.RestoreOn);
        await db.SaveChangesAsync(ct);
        return NoContent();
    }

    /// <summary>"Uyku rutinini 20 dk öne al": moves the child's bedtime routine earlier.</summary>
    [HttpPost("bedtime-earlier")]
    public async Task<IActionResult> BedtimeEarlier(Guid familyId, TipBedtimeRequest request, CancellationToken ct)
    {
        var routine = await db.BedtimeRoutines.FirstOrDefaultAsync(r => r.FamilyId == familyId && r.ChildId == request.ChildId, ct)
                      ?? throw new NotFoundException("bedtime.not_found", "No bedtime routine.");
        routine.Update(routine.Time.AddMinutes(-request.Minutes), routine.Steps, routine.Enabled, routine.LockUntilMorning, routine.Cherries);
        await db.SaveChangesAsync(ct);
        return NoContent();
    }
}
