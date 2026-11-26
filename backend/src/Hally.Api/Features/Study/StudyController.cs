using FluentValidation;
using Hally.Api.Auth;
using Hally.Api.Common;
using Hally.Api.Features.Messages;
using Hally.Api.Features.Notifications;
using Hally.Api.Features.ScreenTime;
using Hally.Domain.Common;
using Hally.Domain.Families;
using Hally.Domain.Notifications;
using Hally.Domain.Study;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.Study;

/// <summary>
/// A child's homework and reading today, as of <see cref="AsOf"/>. <see cref="TodaySeconds"/> already includes the
/// running part; while <see cref="RunningSince"/> is set an app adds the time since <see cref="AsOf"/>, never past
/// <see cref="RunningUntil"/>.
/// </summary>
/// <param name="Streak">Days in a row the goal was met (0 without a goal).</param>
public record ChildStudyDto(
    Guid ChildId,
    int? DailyGoalMinutes,
    int TodaySeconds,
    int HomeworkSeconds,
    int ReadingSeconds,
    string? RunningKind,
    DateTimeOffset? RunningSince,
    DateTimeOffset? RunningUntil,
    string? StartedByName,
    int Streak,
    DateTimeOffset AsOf,
    Guid? StartedByUserId = null,
    Guid? RunningExamId = null);

public record StudyDayDto(DateOnly Date, int HomeworkSeconds, int ReadingSeconds, bool GoalMet);

public record StudyEntryDto(Guid Id, string Kind, DateTimeOffset StartedAt, DateTimeOffset EndedAt, int Seconds, string? Note, string? ByName);

/// <param name="Days">The last seven family-local days, oldest first.</param>
public record ChildStudyHistoryDto(Guid ChildId, int? DailyGoalMinutes, IReadOnlyList<StudyDayDto> Days, IReadOnlyList<StudyEntryDto> Entries);

/// <param name="ExamId">Started from an exam's "Çalışma zamanı": the minutes add up on that exam.</param>
public record StudyStartRequest(StudyKind Kind = StudyKind.Homework, Guid? ExamId = null);

public record StudyStopRequest(string? Note = null);

public record StudyEntryRequest(StudyKind Kind, int Minutes, string? Note = null, Guid? ExamId = null);

/// <param name="DailyMinutes">Null removes the goal.</param>
public record StudyGoalRequest(int? DailyMinutes);

/// <summary>Live note that a child's homework/reading changed; apps reload.</summary>
public record StudyEvent(Guid FamilyId, Guid ChildId);

public class StudyEntryRequestValidator : AbstractValidator<StudyEntryRequest>
{
    public StudyEntryRequestValidator()
    {
        RuleFor(x => x.Minutes).InclusiveBetween(1, (int)StudySession.MaxLength.TotalMinutes);
        RuleFor(x => x.Note).MaximumLength(120);
    }
}

public class StudyGoalRequestValidator : AbstractValidator<StudyGoalRequest>
{
    public StudyGoalRequestValidator() =>
        RuleFor(x => x.DailyMinutes).InclusiveBetween(Child.MinStudyGoal, Child.MaxStudyGoal).When(x => x.DailyMinutes.HasValue);
}

/// <summary>
/// Homework and reading timer per child with a daily minimum ("at least 30 minutes"). The server keeps the timer, so
/// both parents see the same running time; changes go out live on <c>/hubs/chat</c> (<c>StudyChanged</c>). When
/// the day's goal is met, every adult gets one notification for that day.
/// </summary>
[ApiController]
[Authorize(Policy = Policies.FamilyMember)]
[Route("api/v1/families/{familyId:guid}")]
public class StudyController(
    HallyDbContext db,
    NotificationPublisher publisher,
    IHubContext<ChatHub, IChatClient> hub,
    TimeProvider clock,
    ILogger<StudyController> logger) : ControllerBase
{
    /// <summary>How far back the streak looks.</summary>
    private const int StreakDays = 60;

    [CaregiverAllowed]
    [HttpGet("study")]
    public async Task<IReadOnlyList<ChildStudyDto>> Today(Guid familyId, CancellationToken ct)
    {
        var family = await db.Families.AsNoTracking().Include(f => f.Children).FirstAsync(f => f.Id == familyId, ct);
        var result = new List<ChildStudyDto>();
        foreach (var child in family.Children.Where(c => HttpContext.Access().SeesChild(c.Id)).OrderBy(c => c.CreatedAt))
        {
            result.Add(await StatusAsync(family.TimeZoneId, child, ct));
        }

        return result;
    }

    [CaregiverAllowed]
    [HttpGet("children/{childId:guid}/study")]
    public async Task<ChildStudyHistoryDto> History(Guid familyId, Guid childId, CancellationToken ct)
    {
        var (tz, child) = await Load(familyId, childId, ct);
        var now = clock.GetUtcNow();
        var today = FamilyTimeZone.LocalDate(now, tz);
        var bounds = Enumerable.Range(-6, 8).Select(i => FamilyTimeZone.StartOfDay(today.AddDays(i), tz)).ToArray();
        var sessions = await Sessions(childId, bounds[0], bounds[^1], ct);
        var days = Enumerable.Range(0, 7).Select(i => Day(today.AddDays(i - 6), sessions, bounds[i], bounds[i + 1], child.DailyStudyMinutes, now)).ToList();
        var finished = sessions.Where(s => !s.IsCounting(now) && s.StartedAt >= bounds[0]).OrderByDescending(s => s.StartedAt).ToList();
        var ids = finished.Select(s => s.EndedByUserId ?? s.StartedByUserId).OfType<Guid>().Distinct().ToList();
        var names = await db.Users.AsNoTracking().Where(u => ids.Contains(u.Id)).ToDictionaryAsync(u => u.Id, u => u.DisplayName, ct);
        var entries = finished.Select(s =>
        {
            var end = s.CountsUntil(now);
            var by = s.EndedByUserId ?? s.StartedByUserId;
            return new StudyEntryDto(s.Id, s.Kind.ToString(), s.StartedAt, end, (int)(end - s.StartedAt).TotalSeconds, s.Note,
                by is { } u ? names.GetValueOrDefault(u) : null);
        }).ToList();
        return new ChildStudyHistoryDto(childId, child.DailyStudyMinutes, days, entries);
    }

    /// <summary>Starts the child's timer. Already running is not an error: the current status comes back.</summary>
    [CaregiverAllowed]
    [HttpPost("children/{childId:guid}/study/start")]
    public async Task<ChildStudyDto> Start(Guid familyId, Guid childId, StudyStartRequest request, CancellationToken ct)
    {
        await Load(familyId, childId, ct);
        await EnsureExam(childId, request.ExamId, ct);
        var now = clock.GetUtcNow();
        var open = await db.StudySessions.FirstOrDefaultAsync(s => s.ChildId == childId && s.EndedAt == null, ct);
        if (open is not null && !open.IsCounting(now))
        {
            // Forgotten past MaxLength: close it so a new one can start.
            open.Stop(null, null, now);
            open = null;
        }

        if (open is not null && open.ExamId is null && request.ExamId is not null)
        {
            open.ForExam(request.ExamId);
            await db.SaveChangesAsync(ct);
        }

        if (open is null)
        {
            var session = new StudySession(familyId, childId, User.UserId(), request.Kind, now);
            session.ForExam(request.ExamId);
            db.StudySessions.Add(session);
            try
            {
                await db.SaveChangesAsync(ct);
            }
            catch (DbUpdateException)
            {
                // Lost a race with the other parent's Start: the unique index kept one.
                db.ChangeTracker.Clear();
            }
        }

        return await Changed(familyId, childId, ct);
    }

    [CaregiverAllowed]
    [HttpPost("children/{childId:guid}/study/stop")]
    public async Task<ChildStudyDto> Stop(Guid familyId, Guid childId, StudyStopRequest request, CancellationToken ct)
    {
        await Load(familyId, childId, ct);
        var open = await db.StudySessions.FirstOrDefaultAsync(s => s.ChildId == childId && s.EndedAt == null, ct);
        if (open is not null)
        {
            open.Stop(User.UserId(), request.Note, clock.GetUtcNow());
            await db.SaveChangesAsync(ct);
        }

        return await Changed(familyId, childId, ct);
    }

    /// <summary>Adds finished minutes ending now, for when nobody started the timer.</summary>
    [CaregiverAllowed]
    [HttpPost("children/{childId:guid}/study/entries")]
    public async Task<ChildStudyDto> AddEntry(Guid familyId, Guid childId, StudyEntryRequest request, CancellationToken ct)
    {
        await Load(familyId, childId, ct);
        await EnsureExam(childId, request.ExamId, ct);
        var entry = StudySession.Manual(familyId, childId, User.UserId(), request.Kind, TimeSpan.FromMinutes(request.Minutes), request.Note, clock.GetUtcNow());
        entry.ForExam(request.ExamId);
        db.StudySessions.Add(entry);
        await db.SaveChangesAsync(ct);
        return await Changed(familyId, childId, ct);
    }

    [CaregiverAllowed]
    [HttpDelete("children/{childId:guid}/study/{entryId:guid}")]
    public async Task<ChildStudyDto> Delete(Guid familyId, Guid childId, Guid entryId, CancellationToken ct)
    {
        var session = await db.StudySessions.FirstOrDefaultAsync(s => s.Id == entryId && s.ChildId == childId && s.FamilyId == familyId, ct)
                      ?? throw new NotFoundException("study.not_found", "Entry not found.");
        db.StudySessions.Remove(session);
        await db.SaveChangesAsync(ct);
        return await Changed(familyId, childId, ct);
    }

    [HttpPut("children/{childId:guid}/study/goal")]
    public async Task<ChildStudyDto> SetGoal(Guid familyId, Guid childId, StudyGoalRequest request, CancellationToken ct)
    {
        var child = await db.Children.FirstOrDefaultAsync(c => c.FamilyId == familyId && c.Id == childId, ct)
                    ?? throw new NotFoundException("child.not_found", "Child not found.");
        child.SetStudyGoal(request.DailyMinutes);
        await db.SaveChangesAsync(ct);
        return await Changed(familyId, childId, ct);
    }

    private async Task<ChildStudyDto> StatusAsync(string tz, Child child, CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        var today = FamilyTimeZone.LocalDate(now, tz);
        var bounds = Enumerable.Range(-StreakDays + 1, StreakDays + 1).Select(i => FamilyTimeZone.StartOfDay(today.AddDays(i), tz)).ToArray();
        var sessions = await Sessions(child.Id, bounds[0], bounds[^1], ct);
        var days = Enumerable.Range(0, StreakDays)
            .Select(i => Day(today.AddDays(i - StreakDays + 1), sessions, bounds[i], bounds[i + 1], child.DailyStudyMinutes, now)).ToList();
        var todayDay = days[^1];
        var running = sessions.FirstOrDefault(s => s.IsCounting(now));
        string? startedBy = null;
        if (running?.StartedByUserId is { } uid)
        {
            startedBy = await db.Users.AsNoTracking().Where(u => u.Id == uid).Select(u => u.DisplayName).FirstOrDefaultAsync(ct);
        }

        var streak = child.DailyStudyMinutes is null ? 0 : StudySession.Streak(days.Select(d => d.GoalMet).ToList());
        return new ChildStudyDto(child.Id, child.DailyStudyMinutes, todayDay.HomeworkSeconds + todayDay.ReadingSeconds, todayDay.HomeworkSeconds,
            todayDay.ReadingSeconds, running?.Kind.ToString(), running?.StartedAt, running is null ? null : running.StartedAt + StudySession.MaxLength,
            startedBy, streak, now, running?.StartedByUserId, running?.ExamId);
    }

    private static StudyDayDto Day(DateOnly date, List<StudySession> sessions, DateTimeOffset from, DateTimeOffset to, int? goal, DateTimeOffset now)
    {
        int Sum(StudyKind kind) => (int)sessions.Where(s => s.Kind == kind).Aggregate(TimeSpan.Zero, (sum, s) => sum + s.Within(from, to, now)).TotalSeconds;
        var homework = Sum(StudyKind.Homework);
        var reading = Sum(StudyKind.Reading);
        return new StudyDayDto(date, homework, reading, goal is { } g && homework + reading >= g * 60);
    }

    /// <summary>Sessions that can overlap [from, to): sessions never count longer than MaxLength.</summary>
    private Task<List<StudySession>> Sessions(Guid childId, DateTimeOffset from, DateTimeOffset to, CancellationToken ct)
    {
        var earliest = from - StudySession.MaxLength;
        return db.StudySessions.AsNoTracking().Where(s => s.ChildId == childId && s.StartedAt >= earliest && s.StartedAt < to).ToListAsync(ct);
    }

    private async Task EnsureExam(Guid childId, Guid? examId, CancellationToken ct)
    {
        if (examId is { } id && !await db.Exams.AnyAsync(e => e.Id == id && e.ChildId == childId, ct))
        {
            throw new NotFoundException("exam.not_found", "Exam not found.");
        }
    }

    private async Task<(string Tz, Child Child)> Load(Guid familyId, Guid childId, CancellationToken ct)
    {
        var child = await db.Children.AsNoTracking().FirstOrDefaultAsync(c => c.FamilyId == familyId && c.Id == childId, ct)
                    ?? throw new NotFoundException("child.not_found", "Child not found.");
        var tz = await db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.TimeZoneId).FirstAsync(ct);
        return (tz, child);
    }

    private async Task<ChildStudyDto> Changed(Guid familyId, Guid childId, CancellationToken ct)
    {
        var (tz, child) = await Load(familyId, childId, ct);
        var status = await StatusAsync(tz, child, ct);
        var adults = await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == familyId)
            .Join(db.Users.AsNoTracking(), m => m.UserId, u => u.Id, (m, u) => new { u.Id, u.Locale }).ToListAsync(ct);
        try
        {
            await hub.Clients.Groups(adults.Select(a => ChatHub.UserGroup(a.Id)).ToList()).StudyChanged(new StudyEvent(familyId, childId));
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Realtime study event failed");
        }

        // Goal met: one notification per adult per child per family-local day, only once nothing is running.
        if (status.DailyGoalMinutes is { } goal && status.TodaySeconds >= goal * 60 && status.RunningSince is null)
        {
            var day = FamilyTimeZone.LocalDate(status.AsOf, tz);
            var added = false;
            foreach (var adult in adults)
            {
                var (title, body) = StudyTexts.GoalMet(adult.Locale, child.FirstName, goal, status.Streak);
                added |= await publisher.AddAsync(adult.Id, familyId, NotificationKind.StudyGoal, title, body, null, childId,
                    $"study:{childId:N}:{day:yyyyMMdd}:{adult.Id:N}", ct);
            }

            if (added)
            {
                await db.SaveChangesAsync(ct);
                await publisher.FlushPushAsync(ct);
            }
        }

        return status;
    }
}

public static class StudyTexts
{
    public static (string Title, string Body) GoalMet(string locale, string childName, int goalMinutes, int streak)
    {
        var goal = ScreenTimeTexts.Duration(locale, goalMinutes);
        return locale != "en"
            ? ($"{childName}: günlük hedef tamam", streak > 1 ? $"Bugünkü {goal} ödev/okuma tamamlandı. Seri: {streak} gün." : $"Bugünkü {goal} ödev/okuma tamamlandı.")
            : ($"{childName}: daily goal done", streak > 1 ? $"Today's {goal} of homework/reading is done. Streak: {streak} days." : $"Today's {goal} of homework/reading is done.");
    }
}
