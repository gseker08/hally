using System.Globalization;
using System.Text.RegularExpressions;
using Hally.Api.Auth;
using Hally.Api.Common;
using Hally.Api.Features.Activities;
using Hally.Api.Features.Events;
using Hally.Api.Features.Notifications;
using Hally.Domain.Common;
using Hally.Domain.Duties;
using Hally.Domain.Families;
using Hally.Domain.Notifications;
using Hally.Domain.Planning;
using Hally.Domain.Users;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.Briefing;

/// <param name="Kind">Event, DropOff, PickUp, Tasks, Medication, Weather or Empty.</param>
public record BriefingLineDto(string Kind, string Emoji, string Text);

/// <param name="Speech">Everything, for text-to-speech (no emoji).</param>
/// <param name="ShortSpeech">"Daha kısa": the greeting and the counts.</param>
public record BriefingDto(string Day, DateOnly Date, string Greeting, IReadOnlyList<BriefingLineDto> Lines, string Speech, string ShortSpeech);

/// <param name="Time">"HH:mm" (05:00-11:30), or null when the morning notification is off.</param>
public record BriefingSettingsDto(string? Time);

/// <summary>
/// "Bugün ne var?": a short, spoken-friendly summary of a family day built from the family's own data (events,
/// school run, tasks, medicines, weather). No AI is involved, so it works without an AI key.
/// </summary>
public class BriefingService(HallyDbContext db, IWeatherService weather, Medications.MedicationService medications, NotificationPublisher publisher,
    TimeProvider clock, ILogger<BriefingService> logger)
{
    public async Task<BriefingDto> BuildAsync(Guid familyId, Guid userId, bool tomorrow, string? lang, FamilyAccessInfo? access, CancellationToken ct)
    {
        var family = await db.Families.AsNoTracking().FirstAsync(f => f.Id == familyId, ct);
        var tz = family.TimeZoneId;
        var now = clock.GetUtcNow();
        var local = FamilyTimeZone.ToFamilyTime(now, tz);
        var day = DateOnly.FromDateTime(local.DateTime).AddDays(tomorrow ? 1 : 0);
        var (start, end) = (FamilyTimeZone.StartOfDay(day, tz), FamilyTimeZone.StartOfDay(day.AddDays(1), tz));
        lang = Locales.Normalize(lang);
        var culture = Texts.Culture(lang);
        string T(string key, params (string Name, object? Value)[] args) => Texts.Get(lang, key, args);
        var children = await db.Children.AsNoTracking().Where(c => c.FamilyId == familyId).ToDictionaryAsync(c => c.Id, c => c.FirstName, ct);
        var lines = new List<BriefingLineDto>();

        // Events, in time order; all-day ones first.
        var events = (await db.EventsInRangeAsync(familyId, start, end, tz, ct))
            .Where(e => access?.SeesTagged(e.ChildIds) ?? true)
            .OrderBy(e => !e.AllDay).ThenBy(e => e.StartsAt).Take(6).ToList();
        foreach (var e in events)
        {
            var who = e.ChildIds.Select(children.GetValueOrDefault).OfType<string>().ToList();
            var title = who.Count == 0 ? e.Title : $"{e.Title} ({string.Join(", ", who)})";
            lines.Add(new BriefingLineDto("Event", "📅", e.AllDay ? T("brief.allDay", ("title", title)) : $"{Clock(e.StartsAt, tz)} {title}"));
        }

        // The school run: the day's override, else the weekday rule.
        var weekday = ((int)day.DayOfWeek + 6) % 7;
        var rules = await db.DutyRules.AsNoTracking().Where(r => r.FamilyId == familyId && r.Weekday == weekday).ToListAsync(ct);
        var overrides = await db.DutyOverrides.AsNoTracking().Where(o => o.FamilyId == familyId && o.Date == day).ToListAsync(ct);
        foreach (var kind in new[] { DutyKind.DropOff, DutyKind.PickUp })
        {
            DutyAssignment? plan = overrides.FirstOrDefault(o => o.Kind == kind) is { } o ? o : rules.FirstOrDefault(r => r.Kind == kind);
            if (plan is null || (plan.AssigneeUserId is null && plan.AssigneeName is null))
            {
                continue;
            }

            var who = plan.AssigneeName ?? FirstName(await db.Users.AsNoTracking().Where(u => u.Id == plan.AssigneeUserId).Select(u => u.DisplayName).FirstOrDefaultAsync(ct));
            var label = T(kind == DutyKind.DropOff ? "brief.dropOff" : "brief.pickUp");
            lines.Add(new BriefingLineDto(kind.ToString(), "🚗", plan.Time is { } t ? $"{label}: {who}, {t:HH\\:mm}" : $"{label}: {who}"));
        }

        // Tasks due that day, plus the overdue ones (today only).
        var tasks = await db.Tasks.AsNoTracking()
            .Where(t => t.FamilyId == familyId && t.State == TaskState.Open && t.DueAt != null && t.DueAt < end && (tomorrow ? t.DueAt >= start : true))
            .OrderBy(t => t.DueAt).ToListAsync(ct);
        tasks = tasks.Where(t => access?.SeesTagged(t.ChildIds) ?? true).ToList();
        var overdue = tasks.Where(t => t.DueAt < start && !tomorrow).ToList();
        if (tasks.Count > 0)
        {
            var text = Texts.Plural(lang, "brief.tasks", tasks.Count);
            if (overdue.Count > 0)
            {
                text += overdue.Count == 1 ? T("brief.overdueOne", ("title", overdue[0].Title)) : T("brief.overdueMany", ("count", overdue.Count));
            }
            else if (tasks.Count <= 2)
            {
                text += $": {string.Join(", ", tasks.Select(t => t.Title))}";
            }

            lines.Add(new BriefingLineDto("Tasks", "✅", text));
        }

        // Medicines whose next dose falls on that day (only for whoever may see health data).
        if (access is null || access.IsParent || access.CanSeeHealth)
        {
            foreach (var med in await medications.ListAsync(familyId, false, ct))
            {
                if (med.RemindNextDose && med.NextAllowedAt is { } next && next >= start && next < end && (access?.SeesTagged([med.ChildId]) ?? true))
                {
                    var child = children.GetValueOrDefault(med.ChildId);
                    var at = Clock(next, tz);
                    lines.Add(new BriefingLineDto("Medication", "💊",
                        T("brief.medication", ("name", med.Name), ("time", at)) + (child is null ? "" : $" ({child})")));
                }
            }
        }

        // Weather now (today only; the free service gives the current sky).
        if (!tomorrow && family.WeatherLatitude is { } lat && family.WeatherLongitude is { } lon && await weather.CurrentAsync(lat, lon, ct) is { } w)
        {
            var (emoji, sky) = w.Sky switch
            {
                "Clear" => ("☀️", T("weather.clear")),
                "Cloudy" => ("⛅", T("weather.cloudy")),
                "Rain" => ("🌧️", T("weather.rain")),
                "Snow" => ("❄️", T("weather.snow")),
                _ => ("⛈️", T("weather.storm")),
            };
            lines.Add(new BriefingLineDto("Weather", emoji, T("brief.weather", ("temp", w.TemperatureC), ("sky", sky))));
        }

        var name = FirstName(await db.Users.AsNoTracking().Where(u => u.Id == userId).Select(u => u.DisplayName).FirstOrDefaultAsync(ct));
        var hello = local.Hour switch
        {
            < 12 => T("greeting.morning"),
            < 18 => T("greeting.afternoon"),
            _ => T("greeting.evening"),
        };
        var dayName = culture.DateTimeFormat.GetDayName(day.DayOfWeek);
        var greeting = name is null ? $"{hello}!" : $"{hello} {name}!";
        greeting += " " + T(tomorrow ? "brief.tomorrowIs" : "brief.todayIs", ("day", dayName));

        if (lines.Count == 0)
        {
            lines.Add(new BriefingLineDto("Empty", "🙂", tomorrow
                ? T("brief.emptyTomorrow")
                : T("brief.emptyToday")));
        }

        var counts = new List<string>();
        if (events.Count > 0)
        {
            counts.Add(Texts.Plural(lang, "count.events", events.Count));
        }

        if (tasks.Count > 0)
        {
            counts.Add(Texts.Plural(lang, "brief.jobs", tasks.Count));
        }

        var shortSpeech = counts.Count == 0 ? $"{greeting} {lines[0].Text}" : $"{greeting} {T("brief.short", ("counts", string.Join(T("list.and"), counts)))}";
        var speech = $"{greeting} {string.Join(". ", lines.Select(l => l.Text))}.";
        return new BriefingDto(tomorrow ? "tomorrow" : "today", day, greeting, lines, Speakable(speech), Speakable(shortSpeech));
    }

    /// <summary>Hangfire: the morning notification for everyone who set a time.</summary>
    public async Task<int> MorningAsync(CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        var members = await db.FamilyMembers.Where(m => m.BriefingTime != null).ToListAsync(ct);
        var familyIds = members.Select(m => m.FamilyId).Distinct().ToList();
        var zones = await db.Families.AsNoTracking().Where(f => familyIds.Contains(f.Id)).ToDictionaryAsync(f => f.Id, f => f.TimeZoneId, ct);
        var due = members.Where(m => m.HasAccess(now) && m.TakeBriefing(FamilyTimeZone.ToFamilyTime(now, zones[m.FamilyId]).DateTime)).ToList();
        if (due.Count == 0)
        {
            return 0;
        }

        await db.SaveChangesAsync(ct);
        foreach (var m in due)
        {
            try
            {
                var lang = await db.Users.AsNoTracking().Where(u => u.Id == m.UserId).Select(u => u.Locale).FirstAsync(ct);
                var brief = await BuildAsync(m.FamilyId, m.UserId, false, lang, m.IsParent ? null : new FamilyAccessInfo(m.Role, m.ChildIds.Count == 0 ? null : m.ChildIds.ToHashSet(), m.CanSeeHealth), ct);
                var body = string.Join(" · ", brief.Lines.Where(l => l.Kind != "Weather").Take(2).Select(l => $"{l.Emoji} {l.Text}"));
                await publisher.AddAsync(m.UserId, m.FamilyId, NotificationKind.MorningBriefing, "☀️ " + Texts.Get(lang, "brief.push.title"),
                    body, null, null, $"brief:{m.UserId:N}:{m.FamilyId:N}:{brief.Date:yyyyMMdd}", ct);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogWarning(ex, "Morning summary failed");
            }
        }

        await db.SaveChangesAsync(ct);
        await publisher.FlushPushAsync(ct);
        return due.Count;
    }

    private static string Clock(DateTimeOffset at, string tz) => FamilyTimeZone.ToFamilyTime(at, tz).ToString("HH:mm", CultureInfo.InvariantCulture);

    private static string? FirstName(string? displayName) => displayName?.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();

    /// <summary>Text-to-speech reads emoji aloud ("takvim simgesi"), so they go.</summary>
    public static string Speakable(string text) => Regex.Replace(Regex.Replace(text, @"[\p{Cs}\p{So}️‍]", ""), @"\s{2,}", " ").Trim();
}

[ApiController]
[Authorize(Policy = Policies.FamilyMember)]
[CaregiverAllowed]
[Route("api/v1/families/{familyId:guid}/briefing")]
public class BriefingController(HallyDbContext db, BriefingService briefing) : ControllerBase
{
    /// <param name="day">today (default) or tomorrow.</param>
    [HttpGet]
    public Task<BriefingDto> Get(Guid familyId, [FromQuery] string? day, [FromQuery] string? lang, CancellationToken ct)
    {
        var access = HttpContext.Access();
        return briefing.BuildAsync(familyId, User.UserId(), day == "tomorrow", lang, access.IsParent ? null : access, ct);
    }

    [HttpGet("settings")]
    public async Task<BriefingSettingsDto> Settings(Guid familyId, CancellationToken ct)
    {
        var userId = User.UserId();
        var time = await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == familyId && m.UserId == userId).Select(m => m.BriefingTime).FirstAsync(ct);
        return new BriefingSettingsDto(time?.ToString("HH:mm", CultureInfo.InvariantCulture));
    }

    [HttpPut("settings")]
    public async Task<BriefingSettingsDto> SetSettings(Guid familyId, BriefingSettingsDto request, CancellationToken ct)
    {
        TimeOnly? time = null;
        if (!string.IsNullOrWhiteSpace(request.Time))
        {
            if (!TimeOnly.TryParseExact(request.Time, "HH:mm", CultureInfo.InvariantCulture, DateTimeStyles.None, out var t))
            {
                throw new DomainException("briefing.time_invalid", "Time must be HH:mm.");
            }

            time = t;
        }

        var userId = User.UserId();
        var member = await db.FamilyMembers.FirstAsync(m => m.FamilyId == familyId && m.UserId == userId, ct);
        member.SetBriefingTime(time);
        await db.SaveChangesAsync(ct);
        return await Settings(familyId, ct);
    }
}
