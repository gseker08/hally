using Hally.Api.Common;
using Hally.Api.Features.Messages;
using Hally.Api.Features.Notifications;
using Hally.Domain.Common;
using Hally.Domain.Families;
using Hally.Domain.Notifications;
using Hally.Domain.ScreenTime;
using Hally.Domain.Users;
using Hally.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.ScreenTime;

/// <summary>
/// A child's screen time today, as of <see cref="AsOf"/>. <see cref="TodaySeconds"/> already includes the running
/// part, so an app shows <c>TodaySeconds + (time since it got this)</c> while <see cref="RunningSince"/> is set,
/// never counting past <see cref="RunningUntil"/> (forgotten timers stop by themselves).
/// </summary>
public record ChildScreenTimeDto(
    Guid ChildId,
    int? DailyGoalMinutes,
    int TodaySeconds,
    DateTimeOffset? RunningSince,
    DateTimeOffset? RunningUntil,
    Guid? StartedByUserId,
    string? StartedByName,
    DateTimeOffset AsOf);

public record ScreenTimeTodayDto(DateOnly Date, IReadOnlyList<ChildScreenTimeDto> Children);

/// <param name="DailySeconds">Seven values, Monday first.</param>
/// <param name="DaysOverGoal">Days whose total went past the goal (0 without a goal).</param>
public record ChildScreenWeekDto(Guid ChildId, int? DailyGoalMinutes, IReadOnlyList<int> DailySeconds, int TotalSeconds, int AverageSeconds, int DaysOverGoal);

public record ScreenTimeWeekDto(DateOnly Start, DateOnly End, IReadOnlyList<ChildScreenWeekDto> Children);

/// <summary>Live update for one child's screen time, sent to every adult of the family over <c>/hubs/chat</c>.</summary>
public record ScreenTimeEvent(Guid FamilyId, ChildScreenTimeDto Status);

/// <summary>Totals per family-local day, goal checks and the live/push announcements for the screen time timer.</summary>
public class ScreenTimeService(
    HallyDbContext db,
    NotificationPublisher publisher,
    Microsoft.AspNetCore.SignalR.IHubContext<ChatHub, IChatClient> hub,
    TimeProvider clock,
    ILogger<ScreenTimeService> logger)
{
    public async Task<ScreenTimeTodayDto> TodayAsync(Guid familyId, CancellationToken ct)
    {
        var family = await db.Families.AsNoTracking().Include(f => f.Children).FirstAsync(f => f.Id == familyId, ct);
        var now = clock.GetUtcNow();
        var today = FamilyTimeZone.LocalDate(now, family.TimeZoneId);
        var list = new List<ChildScreenTimeDto>();
        foreach (var child in family.Children.OrderBy(c => c.CreatedAt))
        {
            list.Add(await StatusAsync(family, child, now, ct));
        }

        return new ScreenTimeTodayDto(today, list);
    }

    public async Task<ChildScreenTimeDto> StatusAsync(Guid familyId, Guid childId, CancellationToken ct)
    {
        var family = await db.Families.AsNoTracking().FirstAsync(f => f.Id == familyId, ct);
        var child = await db.Children.AsNoTracking().FirstOrDefaultAsync(c => c.FamilyId == familyId && c.Id == childId, ct)
                    ?? throw new NotFoundException("child.not_found", "Child not found.");
        return await StatusAsync(family, child, clock.GetUtcNow(), ct);
    }

    private async Task<ChildScreenTimeDto> StatusAsync(Family family, Child child, DateTimeOffset now, CancellationToken ct)
    {
        var today = FamilyTimeZone.LocalDate(now, family.TimeZoneId);
        var from = FamilyTimeZone.StartOfDay(today, family.TimeZoneId);
        var to = FamilyTimeZone.StartOfDay(today.AddDays(1), family.TimeZoneId);
        var sessions = await SessionsAsync(child.Id, from, to, ct);
        var total = sessions.Aggregate(TimeSpan.Zero, (sum, s) => sum + s.Within(from, to, now));
        var running = sessions.FirstOrDefault(s => s.IsRunning && s.CountsUntil(now) >= now);
        string? startedBy = null;
        if (running?.StartedByUserId is { } uid)
        {
            startedBy = await db.Users.AsNoTracking().Where(u => u.Id == uid).Select(u => u.DisplayName).FirstOrDefaultAsync(ct);
        }

        return new ChildScreenTimeDto(child.Id, child.DailyScreenMinutes, (int)total.TotalSeconds,
            running?.StartedAt, running is null ? null : running.StartedAt + ScreenTimeSession.MaxLength,
            running?.StartedByUserId, startedBy, now);
    }

    /// <summary>Sessions that can overlap [from, to): sessions never count longer than MaxLength.</summary>
    private Task<List<ScreenTimeSession>> SessionsAsync(Guid childId, DateTimeOffset from, DateTimeOffset to, CancellationToken ct)
    {
        var earliest = from - ScreenTimeSession.MaxLength;
        return db.ScreenTimeSessions.AsNoTracking()
            .Where(s => s.ChildId == childId && s.StartedAt >= earliest && s.StartedAt < to)
            .ToListAsync(ct);
    }

    public async Task<ScreenTimeWeekDto> WeekAsync(Guid familyId, DateOnly? start, CancellationToken ct)
    {
        var family = await db.Families.AsNoTracking().Include(f => f.Children).FirstAsync(f => f.Id == familyId, ct);
        var now = clock.GetUtcNow();
        var today = FamilyTimeZone.LocalDate(now, family.TimeZoneId);
        var monday = start ?? today.AddDays(-(((int)today.DayOfWeek + 6) % 7));
        var bounds = Enumerable.Range(0, 8).Select(i => FamilyTimeZone.StartOfDay(monday.AddDays(i), family.TimeZoneId)).ToArray();
        var children = new List<ChildScreenWeekDto>();
        foreach (var child in family.Children.OrderBy(c => c.CreatedAt))
        {
            var sessions = await SessionsAsync(child.Id, bounds[0], bounds[7], ct);
            var days = Enumerable.Range(0, 7)
                .Select(i => (int)sessions.Aggregate(TimeSpan.Zero, (sum, s) => sum + s.Within(bounds[i], bounds[i + 1], now)).TotalSeconds)
                .ToList();
            var total = days.Sum();
            // Average over the days that have started (all seven for a past week).
            var elapsedDays = Math.Clamp(today.DayNumber - monday.DayNumber + 1, 1, 7);
            var over = child.DailyScreenMinutes is { } goal ? days.Count(d => d > goal * 60) : 0;
            children.Add(new ChildScreenWeekDto(child.Id, child.DailyScreenMinutes, days, total, total / elapsedDays, over));
        }

        return new ScreenTimeWeekDto(monday, monday.AddDays(6), children);
    }

    /// <summary>Tells every adult's open apps about the child's new status. Best effort.</summary>
    public async Task AnnounceAsync(Guid familyId, ChildScreenTimeDto status, CancellationToken ct)
    {
        try
        {
            var adults = await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == familyId).Select(m => m.UserId).ToListAsync(ct);
            var e = new ScreenTimeEvent(familyId, status);
            await hub.Clients.Groups(adults.Select(ChatHub.UserGroup).ToList()).ScreenTimeChanged(e);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Realtime screen time event failed");
        }
    }

    /// <summary>
    /// When today's total has reached the child's goal, adds one inbox entry per adult (and pushes it). The dedup key
    /// keeps it to once per child per family-local day, however often this runs.
    /// </summary>
    /// <returns>Whether new notifications were added.</returns>
    public async Task<bool> NotifyIfGoalReachedAsync(Guid familyId, ChildScreenTimeDto status, CancellationToken ct)
    {
        if (status.DailyGoalMinutes is not { } goal || status.TodaySeconds < goal * 60)
        {
            return false;
        }

        var family = await db.Families.AsNoTracking().FirstAsync(f => f.Id == familyId, ct);
        var child = await db.Children.AsNoTracking().FirstAsync(c => c.Id == status.ChildId, ct);
        var day = FamilyTimeZone.LocalDate(status.AsOf, family.TimeZoneId);
        var adults = await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == familyId)
            .Join(db.Users.AsNoTracking(), m => m.UserId, u => u.Id, (m, u) => new { u.Id, u.Locale }).ToListAsync(ct);
        var added = false;
        foreach (var adult in adults)
        {
            var (title, body) = ScreenTimeTexts.GoalReached(adult.Locale, child.FirstName, goal, status.RunningSince is not null);
            added |= await publisher.AddAsync(adult.Id, familyId, NotificationKind.ScreenTimeGoal, title, body, null, child.Id,
                $"st:{child.Id:N}:{day:yyyyMMdd}:{adult.Id:N}", ct);
        }

        if (added)
        {
            await db.SaveChangesAsync(ct);
            await publisher.FlushPushAsync(ct);
        }

        return added;
    }
}

public static class ScreenTimeTexts
{
    public static string Duration(string locale, int minutes)
    {
        var h = minutes / 60;
        var m = minutes % 60;
        var (hu, mu) = (Texts.Get(locale, "unit.hours"), Texts.Get(locale, "unit.minutes"));
        return (h, m) switch
        {
            (0, _) => $"{m} {mu}",
            (_, 0) => $"{h} {hu}",
            _ => $"{h} {hu} {m} {mu}",
        };
    }

    public static (string Title, string Body) GoalReached(string locale, string childName, int goalMinutes, bool stillRunning)
    {
        var goal = Duration(locale, goalMinutes);
        return (Texts.Get(locale, "screen.goal.title", ("name", childName)),
            Texts.Get(locale, stillRunning ? "screen.goal.bodyRunning" : "screen.goal.body", ("goal", goal)));
    }
}

/// <summary>Every minute: running timers whose child has passed today's goal get the goal notification
/// (once per child per day, see <see cref="ScreenTimeService.NotifyIfGoalReachedAsync"/>).
/// Also closes timers that hit <see cref="ScreenTimeSession.MaxLength"/>, so the apps stop showing them as running.</summary>
public class ScreenTimeGoalJob(HallyDbContext db, ScreenTimeService screenTime, TimeProvider clock, ILogger<ScreenTimeGoalJob> logger)
{
    public async Task<int> RunAsync(CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        var running = await db.ScreenTimeSessions.Where(s => s.EndedAt == null).ToListAsync(ct);
        var notified = 0;
        foreach (var session in running)
        {
            if (session.CountsUntil(now) < now)
            {
                session.Stop(null, now);
                await db.SaveChangesAsync(ct);
                await screenTime.AnnounceAsync(session.FamilyId, await screenTime.StatusAsync(session.FamilyId, session.ChildId, ct), ct);
                continue;
            }

            var status = await screenTime.StatusAsync(session.FamilyId, session.ChildId, ct);
            if (await screenTime.NotifyIfGoalReachedAsync(session.FamilyId, status, ct))
            {
                notified++;
            }
        }

        if (notified > 0)
        {
            logger.LogInformation("Screen time: {Count} goal notifications", notified);
        }

        return notified;
    }
}
