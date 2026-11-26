using System.Text.RegularExpressions;
using FluentValidation;
using Hally.Api.Auth;
using Hally.Api.Common;
using Hally.Api.Features.ChildMode;
using Hally.Api.Features.Events;
using Hally.Api.Features.Messages;
using Hally.Api.Features.Notifications;
using Hally.Api.Features.Points;
using Hally.Domain.ChildMode;
using Hally.Domain.Common;
using Hally.Domain.Families;
using Hally.Domain.Notifications;
using Hally.Domain.Planning;
using Hally.Domain.Points;
using Hally.Domain.School;
using Hally.Domain.Users;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.Exams;

/// <param name="DaysLeft">Family-local days until the exam (0 = today, negative = past).</param>
/// <param name="StudySeconds">Homework time started from this exam's "Çalışma zamanı" rows.</param>
/// <param name="Outcome">Hard, Good or Great; null until a parent notes it, and always null for caregivers.</param>
public record ExamDto(
    Guid Id,
    Guid ChildId,
    string ChildName,
    string Subject,
    string? Topics,
    DateOnly Date,
    string? Slot,
    int? StudyDaysBefore,
    Guid? EventId,
    int DaysLeft,
    int StudySeconds,
    string? Outcome,
    int? Score,
    int Cherries,
    bool StudyDay);

/// <param name="StudyDaysBefore">1, 2, 3 or 7; null turns the evening study notes off.</param>
public record ExamRequest(Guid ChildId, string Subject, string? Topics, DateOnly Date, string? Slot, int? StudyDaysBefore = 3);

public record ExamResultRequest(ExamOutcome Outcome, int? Score = null, int Cherries = 0);

/// <summary>On the child's phone (Bugünüm): an exam in the next two weeks.</summary>
/// <param name="State">"Çalıştım" today: Todo, Pending (waits for a parent) or Done.</param>
public record ChildExamDto(Guid Id, string Subject, string? Topics, DateOnly Date, string? Slot, int DaysLeft, int StudySeconds, string State);

/// <summary>Live note that a family's exams changed; apps reload.</summary>
public record ExamsEvent(Guid FamilyId);

public class ExamRequestValidator : AbstractValidator<ExamRequest>
{
    public ExamRequestValidator()
    {
        RuleFor(x => x.Subject).NotEmpty().MaximumLength(Exam.MaxSubject);
        RuleFor(x => x.Topics).MaximumLength(Exam.MaxTopics);
        RuleFor(x => x.Slot).MaximumLength(Exam.MaxSlot);
        RuleFor(x => x.StudyDaysBefore).Must(d => d is null || Exam.StudyDayChoices.Contains(d.Value)).WithMessage("Study reminders start 1, 2, 3 or 7 days before.");
    }
}

public class ExamResultRequestValidator : AbstractValidator<ExamResultRequest>
{
    public ExamResultRequestValidator()
    {
        RuleFor(x => x.Outcome).IsInEnum();
        RuleFor(x => x.Score).InclusiveBetween(0, 100).When(x => x.Score.HasValue);
        RuleFor(x => x.Cherries).InclusiveBetween(0, Exam.MaxCherries);
    }
}

/// <summary>
/// Sınav takvimi: a child's exams, each kept in step with one calendar event tagged with the child. Evenings before an
/// exam the parents get "Çalışma zamanı"; on the exam day "Nasıl geçti?". A result (how it went, optional score) is for
/// parents only and can give cherries once.
/// </summary>
public class ExamService(HallyDbContext db, NotificationPublisher publisher, IHubContext<ChatHub, IChatClient> hub, TimeProvider clock, ILogger<ExamService> logger)
{
    /// <summary>How far back finished exams are listed.</summary>
    public const int PastDays = 60;

    /// <summary>The child's phone shows exams this many days ahead.</summary>
    public const int ChildAheadDays = 14;

    /// <summary>Family-local hour of the evening notes.</summary>
    public const int EveningHour = 18;

    private static readonly Regex SlotTime = new(@"^(?<h>[01]?\d|2[0-3])[:.](?<m>[0-5]\d)$", RegexOptions.CultureInvariant);

    public async Task<IReadOnlyList<ExamDto>> ListAsync(Guid familyId, Guid? childId, FamilyAccessInfo access, CancellationToken ct)
    {
        var tz = await db.FamilyTimeZoneAsync(familyId, ct);
        var today = FamilyTimeZone.LocalDate(clock.GetUtcNow(), tz);
        var since = today.AddDays(-PastDays);
        var exams = await db.Exams.AsNoTracking()
            .Where(e => e.FamilyId == familyId && e.Date >= since && (childId == null || e.ChildId == childId))
            .OrderBy(e => e.Date).ThenBy(e => e.CreatedAt).ToListAsync(ct);
        exams = exams.Where(e => access.SeesChild(e.ChildId)).ToList();
        return await ToDtosAsync(exams, today, access.IsParent, ct);
    }

    public async Task<ExamDto> GetAsync(Guid familyId, Guid examId, FamilyAccessInfo access, CancellationToken ct)
    {
        var exam = await db.Exams.AsNoTracking().FirstOrDefaultAsync(e => e.Id == examId && e.FamilyId == familyId, ct);
        if (exam is null || !access.SeesChild(exam.ChildId))
        {
            throw new NotFoundException("exam.not_found", "Exam not found.");
        }

        var tz = await db.FamilyTimeZoneAsync(familyId, ct);
        return (await ToDtosAsync([exam], FamilyTimeZone.LocalDate(clock.GetUtcNow(), tz), access.IsParent, ct))[0];
    }

    public async Task<ExamDto> SaveAsync(Guid familyId, Guid? examId, ExamRequest request, Guid userId, CancellationToken ct)
    {
        if (!await db.Children.AnyAsync(c => c.Id == request.ChildId && c.FamilyId == familyId, ct))
        {
            throw new DomainException("exam.child_not_in_family", "The child does not belong to this family.");
        }

        var family = await db.Families.AsNoTracking().FirstAsync(f => f.Id == familyId, ct);
        var now = clock.GetUtcNow();
        var today = FamilyTimeZone.LocalDate(now, family.TimeZoneId);
        if (request.Date < today.AddDays(-PastDays) || request.Date > today.AddDays(400))
        {
            throw new DomainException("exam.date_invalid", "The exam date is too far away.");
        }

        Exam exam;
        if (examId is { } id)
        {
            exam = await db.Exams.FirstOrDefaultAsync(e => e.Id == id && e.FamilyId == familyId, ct)
                   ?? throw new NotFoundException("exam.not_found", "Exam not found.");
        }
        else
        {
            exam = new Exam(familyId, request.ChildId, userId, now);
            db.Exams.Add(exam);
        }

        exam.Update(request.ChildId, request.Subject, request.Topics, request.Date, request.Slot, request.StudyDaysBefore);
        var lang = Locales.Normalize(await db.Users.AsNoTracking().Where(u => u.Id == (exam.CreatedByUserId ?? userId)).Select(u => u.Locale).FirstOrDefaultAsync(ct));
        var (start, end, allDay) = EventTimes(exam, family.TimeZoneId);
        var evt = exam.EventId is { } eventId ? await db.Events.FirstOrDefaultAsync(e => e.Id == eventId, ct) : null;
        if (evt is null)
        {
            evt = new CalendarEvent(familyId, userId, exam.EventTitle(lang), start, end, allDay, null, [exam.ChildId]);
            db.Events.Add(evt);
            exam.LinkEvent(evt.Id);
        }
        else
        {
            evt.Update(exam.EventTitle(lang), start, end, allDay, evt.Location, [exam.ChildId]);
            evt.SetRepeat(EventRepeat.None, null);
        }

        db.AuditEntries.Add(new AuditEntry
        {
            FamilyId = familyId,
            ActorUserId = userId,
            Action = examId is null ? "exam.created" : "exam.updated",
            EntityType = "exam",
            EntityId = exam.Id,
            At = now,
        });
        await db.SaveChangesAsync(ct);
        await AnnounceAsync(familyId, ct);
        return (await ToDtosAsync([exam], today, true, ct))[0];
    }

    public async Task DeleteAsync(Guid familyId, Guid examId, Guid userId, CancellationToken ct)
    {
        var exam = await db.Exams.FirstOrDefaultAsync(e => e.Id == examId && e.FamilyId == familyId, ct)
                   ?? throw new NotFoundException("exam.not_found", "Exam not found.");
        if (exam.EventId is { } eventId && await db.Events.FirstOrDefaultAsync(e => e.Id == eventId, ct) is { } evt)
        {
            db.Events.Remove(evt);
        }

        db.Exams.Remove(exam);
        db.AuditEntries.Add(new AuditEntry { FamilyId = familyId, ActorUserId = userId, Action = "exam.deleted", EntityType = "exam", EntityId = exam.Id, At = clock.GetUtcNow() });
        await db.SaveChangesAsync(ct);
        await AnnounceAsync(familyId, ct);
    }

    /// <summary>How it went. Cherries go into the child's jar the first time they are given.</summary>
    public async Task<ExamDto> ResultAsync(Guid familyId, Guid examId, ExamResultRequest request, Guid userId, CancellationToken ct)
    {
        var exam = await db.Exams.FirstOrDefaultAsync(e => e.Id == examId && e.FamilyId == familyId, ct)
                   ?? throw new NotFoundException("exam.not_found", "Exam not found.");
        var tz = await db.FamilyTimeZoneAsync(familyId, ct);
        var now = clock.GetUtcNow();
        var today = FamilyTimeZone.LocalDate(now, tz);
        var add = exam.SetResult(request.Outcome, request.Score, request.Cherries, userId, today, now);
        if (add > 0)
        {
            db.PointEntries.Add(PointEntry.ForExam(familyId, exam.ChildId, exam.Subject, add, userId, today, now));
        }

        await db.SaveChangesAsync(ct);
        await AnnounceAsync(familyId, ct, points: add > 0);
        return (await ToDtosAsync([exam], today, true, ct))[0];
    }

    /// <summary>
    /// Every 15 minutes: from <see cref="EveningHour"/> family time, "Çalışma zamanı" on the study evenings and "Nasıl
    /// geçti?" on the exam day (until a result is in). The dedup key keeps it to one per exam, parent and evening.
    /// </summary>
    public async Task<int> EveningAsync(CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        var utcToday = DateOnly.FromDateTime(now.UtcDateTime);
        var from = utcToday.AddDays(-1);
        var to = utcToday.AddDays(Exam.StudyDayChoices.Max() + 1);
        var exams = await db.Exams.AsNoTracking().Where(e => e.Date >= from && e.Date <= to).ToListAsync(ct);
        if (exams.Count == 0)
        {
            return 0;
        }

        var familyIds = exams.Select(e => e.FamilyId).Distinct().ToList();
        var zones = await db.Families.AsNoTracking().Where(f => familyIds.Contains(f.Id)).ToDictionaryAsync(f => f.Id, f => f.TimeZoneId, ct);
        var childIds = exams.Select(e => e.ChildId).Distinct().ToList();
        var names = await db.Children.AsNoTracking().Where(c => childIds.Contains(c.Id)).ToDictionaryAsync(c => c.Id, c => c.FirstName, ct);
        var parents = (await db.FamilyMembers.AsNoTracking().Where(m => familyIds.Contains(m.FamilyId) && m.Role != FamilyRole.Caregiver)
                .Join(db.Users.AsNoTracking(), m => m.UserId, u => u.Id, (m, u) => new { m.FamilyId, u.Id, u.Locale }).ToListAsync(ct))
            .ToLookup(p => p.FamilyId);
        var added = 0;
        foreach (var exam in exams)
        {
            var local = FamilyTimeZone.ToFamilyTime(now, zones[exam.FamilyId]);
            if (local.Hour < EveningHour)
            {
                continue;
            }

            var today = DateOnly.FromDateTime(local.DateTime);
            var name = names.GetValueOrDefault(exam.ChildId, "");
            foreach (var p in parents[exam.FamilyId])
            {
                var lang = Locales.Normalize(p.Locale);
                if (exam.IsStudyDay(today))
                {
                    var (title, body) = ExamTexts.Study(lang, name, exam.Subject, exam.Topics, exam.Date.DayNumber - today.DayNumber);
                    if (await publisher.AddAsync(p.Id, exam.FamilyId, NotificationKind.ExamStudy, title, body, null, exam.Id, $"exam-study:{exam.Id:N}:{today:yyyyMMdd}:{p.Id:N}", ct))
                    {
                        added++;
                    }
                }
                else if (exam.Date == today && !exam.HasResult)
                {
                    var (title, body) = ExamTexts.HowDidItGo(lang, name, exam.Subject);
                    if (await publisher.AddAsync(p.Id, exam.FamilyId, NotificationKind.ExamResult, title, body, null, exam.Id, $"exam-result:{exam.Id:N}:{p.Id:N}", ct))
                    {
                        added++;
                    }
                }
            }
        }

        if (added > 0)
        {
            await db.SaveChangesAsync(ct);
            await publisher.FlushPushAsync(ct);
        }

        return added;
    }

    /// <summary>
    /// A calendar event approved from a scanned school note ("Matematik sınavı", one child tagged) also becomes an exam,
    /// so it gets study notes and a result. Caller saves.
    /// </summary>
    public async Task<Exam?> FromEventAsync(CalendarEvent evt, Guid userId, CancellationToken ct)
    {
        if (evt.ChildIds.Count != 1 || evt.Repeat != EventRepeat.None || ExamTexts.SubjectOf(evt.Title) is not { } subject)
        {
            return null;
        }

        var tz = await db.FamilyTimeZoneAsync(evt.FamilyId, ct);
        var local = FamilyTimeZone.ToFamilyTime(evt.StartsAt, tz);
        var exam = new Exam(evt.FamilyId, evt.ChildIds[0], userId, clock.GetUtcNow());
        exam.Update(evt.ChildIds[0], subject, null, DateOnly.FromDateTime(local.DateTime), evt.AllDay ? null : local.ToString("HH:mm"), 3);
        exam.LinkEvent(evt.Id);
        db.Exams.Add(exam);
        return exam;
    }

    /// <summary>The calendar event moved: the exam follows its day.</summary>
    public async Task FollowEventAsync(CalendarEvent evt, CancellationToken ct)
    {
        var exam = await db.Exams.FirstOrDefaultAsync(e => e.EventId == evt.Id, ct);
        if (exam is null)
        {
            return;
        }

        var tz = await db.FamilyTimeZoneAsync(evt.FamilyId, ct);
        var day = DateOnly.FromDateTime(FamilyTimeZone.ToFamilyTime(evt.StartsAt, tz).DateTime);
        var child = evt.ChildIds.Count == 1 ? evt.ChildIds[0] : exam.ChildId;
        exam.Update(child, exam.Subject, exam.Topics, day, exam.Slot, exam.StudyDaysBefore);
    }

    public static (DateTimeOffset Start, DateTimeOffset? End, bool AllDay) EventTimes(Exam exam, string tz)
    {
        var start = FamilyTimeZone.StartOfDay(exam.Date, tz);
        if (exam.Slot is { } slot && SlotTime.Match(slot) is { Success: true } m)
        {
            var zone = TimeZoneInfo.FindSystemTimeZoneById(tz);
            var local = exam.Date.ToDateTime(new TimeOnly(int.Parse(m.Groups["h"].Value), int.Parse(m.Groups["m"].Value)));
            var at = new DateTimeOffset(local, zone.GetUtcOffset(local)).ToUniversalTime();
            return (at, at.AddMinutes(40), false);
        }

        return (start, null, true);
    }

    private async Task<Dictionary<Guid, int>> StudySecondsAsync(List<Guid> examIds, CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        var sessions = await db.StudySessions.AsNoTracking().Where(s => s.ExamId != null && examIds.Contains(s.ExamId.Value)).ToListAsync(ct);
        return sessions.GroupBy(s => s.ExamId!.Value).ToDictionary(g => g.Key, g => (int)g.Sum(s => (s.CountsUntil(now) - s.StartedAt).TotalSeconds));
    }

    private async Task<List<ExamDto>> ToDtosAsync(List<Exam> exams, DateOnly today, bool parent, CancellationToken ct)
    {
        var childIds = exams.Select(e => e.ChildId).Distinct().ToList();
        var names = await db.Children.AsNoTracking().Where(c => childIds.Contains(c.Id)).ToDictionaryAsync(c => c.Id, c => c.FirstName, ct);
        var seconds = await StudySecondsAsync(exams.Select(e => e.Id).ToList(), ct);
        return exams.Select(e => new ExamDto(e.Id, e.ChildId, names.GetValueOrDefault(e.ChildId, ""), e.Subject, e.Topics, e.Date, e.Slot, e.StudyDaysBefore, e.EventId,
            e.Date.DayNumber - today.DayNumber, seconds.GetValueOrDefault(e.Id),
            parent ? e.Outcome?.ToString() : null, parent ? e.Score : null, parent ? e.Cherries : 0, e.IsStudyDay(today))).ToList();
    }

    private async Task AnnounceAsync(Guid familyId, CancellationToken ct, bool points = false)
    {
        try
        {
            var members = await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == familyId).Select(m => m.UserId).ToListAsync(ct);
            var groups = members.Select(ChatHub.UserGroup).ToList();
            await hub.Clients.Groups(groups).ExamsChanged(new ExamsEvent(familyId));
            if (points)
            {
                await hub.Clients.Groups(groups).PointsChanged(new PointsEvent(familyId));
            }
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Realtime exams event failed");
        }
    }
}

public static class ExamTexts
{
    private static readonly Regex ExamWord = new(@"\b(sınavı|sınavları|sınav|yazılısı|yazılı|quiz|exam|test|klassenarbeit|prüfung|schulaufgabe|lernkontrolle)\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    public static (string Title, string Body) Study(string lang, string child, string subject, string? topics, int daysLeft)
    {
        var when = daysLeft == 1
            ? Texts.Get(lang, "exam.study.tomorrow", ("subject", subject))
            : Texts.Get(lang, "exam.study.inDays", ("subject", subject), ("days", daysLeft));
        var topic = string.IsNullOrWhiteSpace(topics) ? "" : " " + Texts.Get(lang, "exam.study.topics", ("topics", topics));
        return (Texts.Get(lang, "exam.study.title", ("name", child)), when + topic + " " + Texts.Get(lang, "exam.study.nudge"));
    }

    public static (string Title, string Body) HowDidItGo(string lang, string child, string subject) =>
        (Texts.Get(lang, "exam.result.title", ("name", child), ("subject", subject)), Texts.Get(lang, "exam.result.body"));

    /// <summary>"Matematik sınavı" → "Matematik"; null when the title is not about an exam.</summary>
    public static string? SubjectOf(string title)
    {
        var clean = title.Replace("📝", "").Trim();
        if (!ExamWord.IsMatch(clean))
        {
            return null;
        }

        var subject = ExamWord.Replace(clean, "").Trim(' ', '-', ':', '·', ',');
        subject = Regex.Replace(subject, @"\s+", " ");
        if (subject.Length == 0)
        {
            subject = clean;
        }

        return subject.Length > Exam.MaxSubject ? subject[..Exam.MaxSubject].Trim() : subject;
    }
}

/// <summary>Parents add, edit and note results; caregivers see the dates (never results).</summary>
[ApiController]
[Authorize(Policy = Policies.FamilyMember)]
[Route("api/v1/families/{familyId:guid}/exams")]
public class ExamsController(ExamService exams) : ControllerBase
{
    [CaregiverAllowed]
    [HttpGet]
    public Task<IReadOnlyList<ExamDto>> List(Guid familyId, [FromQuery] Guid? child, CancellationToken ct) =>
        exams.ListAsync(familyId, child, HttpContext.Access(), ct);

    [CaregiverAllowed]
    [HttpGet("{examId:guid}")]
    public Task<ExamDto> Get(Guid familyId, Guid examId, CancellationToken ct) => exams.GetAsync(familyId, examId, HttpContext.Access(), ct);

    [HttpPost]
    [ProducesResponseType<ExamDto>(201)]
    public async Task<IActionResult> Create(Guid familyId, ExamRequest request, CancellationToken ct) =>
        StatusCode(201, await exams.SaveAsync(familyId, null, request, User.UserId(), ct));

    [HttpPut("{examId:guid}")]
    public Task<ExamDto> Update(Guid familyId, Guid examId, ExamRequest request, CancellationToken ct) =>
        exams.SaveAsync(familyId, examId, request, User.UserId(), ct);

    [HttpDelete("{examId:guid}")]
    public async Task<IActionResult> Delete(Guid familyId, Guid examId, CancellationToken ct)
    {
        await exams.DeleteAsync(familyId, examId, User.UserId(), ct);
        return NoContent();
    }

    [HttpPut("{examId:guid}/result")]
    public Task<ExamDto> Result(Guid familyId, Guid examId, ExamResultRequest request, CancellationToken ct) =>
        exams.ResultAsync(familyId, examId, request, User.UserId(), ct);
}

/// <summary>The child's phone: "Çalıştım" for an upcoming exam (one cherry a day, with the usual parent approval).</summary>
[ApiController]
[Authorize(Policy = ChildDeviceAuth.Policy)]
[Route("api/v1/child/exams")]
public class ChildExamsController(ChildModeService childMode) : ControllerBase
{
    [HttpPost("{examId:guid}/studied")]
    public async Task<IActionResult> Studied(Guid examId, CancellationToken ct)
    {
        await childMode.MarkDoneAsync(User.ChildFamilyId(), User.ChildId(), ClaimKind.Study, examId, ct);
        return NoContent();
    }
}
