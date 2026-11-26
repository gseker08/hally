using FluentValidation;
using Hally.Api.Auth;
using Hally.Api.Common;
using Hally.Api.Features.ChildMode;
using Hally.Api.Features.Events;
using Hally.Api.Features.Messages;
using Hally.Api.Features.Notifications;
using Hally.Domain.ChildMode;
using Hally.Domain.Common;
using Hally.Domain.Families;
using Hally.Domain.Notifications;
using Hally.Domain.School;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.School;

/// <param name="ReminderTime">"19:30", or null when the evening note is off.</param>
public record SchoolSettingsDto(IReadOnlyList<string> BellTimes, IReadOnlyList<string> DailyItems, string? ReminderTime, bool ChildPhone, bool QuietOnHolidays);

public record SchoolSettingsRequest(IReadOnlyList<string>? BellTimes, IReadOnlyList<string>? DailyItems, string? ReminderTime, bool ChildPhone = true, bool QuietOnHolidays = true);

public record SchoolBreakDto(Guid Id, string Title, DateOnly From, DateOnly To);

public record SchoolBreakRequest(string Title, DateOnly From, DateOnly To);

/// <param name="Weekday">1 = Monday … 5 = Friday.</param>
public record LessonDto(Guid Id, Guid ChildId, int Weekday, int Period, string Subject, IReadOnlyList<string> Items);

/// <summary>Sets one period; an empty subject clears it.</summary>
public record LessonRequest(Guid ChildId, int Weekday, int Period, string? Subject, IReadOnlyList<string>? Items);

/// <param name="Key">The item text, or "exam:{id}" for an exam.</param>
/// <param name="Kind">"Item" (to pack) or "Exam" (to study for; <see cref="ExamDate"/> says when).</param>
/// <param name="Subjects">The lessons that need the item; empty for every-day items.</param>
public record BagItemDto(string Key, string Kind, string Text, IReadOnlyList<string> Subjects, DateOnly? ExamDate, bool Packed);

/// <param name="Day">The school day the bag is for (tomorrow).</param>
/// <param name="ChildClaim">The child's "Çantam hazır" today: null, "Pending" (waits for a parent) or "Done".</param>
public record BagDto(Guid ChildId, string ChildName, DateOnly Day, IReadOnlyList<string> Subjects, IReadOnlyList<BagItemDto> Items, DateTimeOffset? ReadyAt, bool ReadyByChild, string? ChildClaim);

public record SchoolDto(DateOnly Today, bool TodayIsSchoolDay, SchoolSettingsDto Settings, IReadOnlyList<SchoolBreakDto> Breaks, IReadOnlyList<LessonDto> Lessons, IReadOnlyList<BagDto> Bags);

public record BagItemRequest(string Key, bool Packed);

/// <param name="Start">The bell time, "08:30".</param>
/// <param name="Now">The lesson going on right now.</param>
public record ChildLessonDto(int Period, string? Start, string Subject, IReadOnlyList<string> Items, bool Now);

/// <summary>On the child's phone: today's lessons, and tomorrow's bag when the parents allow it.</summary>
public record ChildSchoolDto(IReadOnlyList<ChildLessonDto> Today, BagDto? Bag);

/// <summary>Live note that a family's timetable or bags changed; apps reload.</summary>
public record SchoolEvent(Guid FamilyId);

public class SchoolSettingsRequestValidator : AbstractValidator<SchoolSettingsRequest>
{
    public SchoolSettingsRequestValidator()
    {
        RuleFor(x => x.BellTimes).Must(b => b is null || b.Count <= SchoolPlan.MaxPeriods);
        RuleFor(x => x.DailyItems).Must(i => i is null || i.Count <= SchoolPlan.MaxItems);
        RuleFor(x => x.ReminderTime).Must(t => t is null || TimeOnly.TryParseExact(t, "HH:mm", out _)).WithMessage("Reminder time looks like 19:30.");
    }
}

public class LessonRequestValidator : AbstractValidator<LessonRequest>
{
    public LessonRequestValidator()
    {
        RuleFor(x => x.Weekday).InclusiveBetween(1, 5);
        RuleFor(x => x.Period).InclusiveBetween(1, SchoolPlan.MaxPeriods);
        RuleFor(x => x.Subject).MaximumLength(Exam.MaxSubject);
        RuleFor(x => x.Items).Must(i => i is null || i.Count <= SchoolPlan.MaxItems);
    }
}

/// <summary>Reads timetables and bags; shared by the parents' screens, the evening job and the child's phone.</summary>
public class SchoolReader(HallyDbContext db, TimeProvider clock)
{
    /// <summary>The family's settings, or the defaults when none were saved yet (not added to the context).</summary>
    public async Task<SchoolPlan> PlanAsync(Guid familyId, CancellationToken ct) =>
        await db.SchoolPlans.AsNoTracking().FirstOrDefaultAsync(p => p.FamilyId == familyId, ct) ?? new SchoolPlan(familyId, clock.GetUtcNow());

    public Task<List<SchoolBreak>> BreaksAsync(Guid familyId, DateOnly from, CancellationToken ct) =>
        db.SchoolBreaks.AsNoTracking().Where(b => b.FamilyId == familyId && b.To >= from).OrderBy(b => b.From).ToListAsync(ct);

    /// <summary>Tomorrow's bag for each child with lessons tomorrow; empty when tomorrow is no school day.</summary>
    public async Task<List<BagDto>> BagsAsync(Guid familyId, SchoolPlan plan, List<SchoolBreak> breaks, DateOnly today, IReadOnlyCollection<Guid>? childIds, CancellationToken ct)
    {
        var day = today.AddDays(1);
        if (!plan.IsSchoolDay(day, breaks))
        {
            return [];
        }

        var weekday = Lesson.WeekdayOf(day);
        var lessons = await db.Lessons.AsNoTracking()
            .Where(l => l.FamilyId == familyId && l.Weekday == weekday && (childIds == null || childIds.Contains(l.ChildId)))
            .OrderBy(l => l.Period).ToListAsync(ct);
        if (lessons.Count == 0)
        {
            return [];
        }

        var ids = lessons.Select(l => l.ChildId).Distinct().ToList();
        var children = await db.Children.AsNoTracking().Where(c => ids.Contains(c.Id)).OrderBy(c => c.CreatedAt).Select(c => new { c.Id, c.FirstName }).ToListAsync(ct);
        var checks = await db.BagChecks.AsNoTracking().Where(b => ids.Contains(b.ChildId) && b.Day == day).ToListAsync(ct);
        var examUntil = today.AddDays(7);
        var exams = await db.Exams.AsNoTracking().Where(e => ids.Contains(e.ChildId) && e.Date >= day && e.Date <= examUntil).OrderBy(e => e.Date).ToListAsync(ct);
        var claims = await db.ChildClaims.AsNoTracking()
            .Where(c => ids.Contains(c.ChildId) && c.Kind == ClaimKind.Bag && c.Day == today && c.Status != ClaimStatus.Rejected)
            .Select(c => new { c.ChildId, c.Status }).ToListAsync(ct);

        var bags = new List<BagDto>();
        foreach (var child in children)
        {
            var mine = lessons.Where(l => l.ChildId == child.Id).ToList();
            var check = checks.FirstOrDefault(c => c.ChildId == child.Id);
            var packed = check?.Packed ?? [];
            var items = new List<BagItemDto>();
            foreach (var lesson in mine)
            {
                foreach (var item in lesson.Items)
                {
                    var i = items.FindIndex(x => x.Key == item);
                    if (i < 0)
                    {
                        items.Add(new BagItemDto(item, "Item", item, [lesson.Subject], null, packed.Contains(item)));
                    }
                    else if (!items[i].Subjects.Contains(lesson.Subject))
                    {
                        items[i] = items[i] with { Subjects = [.. items[i].Subjects, lesson.Subject] };
                    }
                }
            }

            foreach (var item in plan.DailyItems.Where(d => items.All(x => x.Key != d)))
            {
                items.Add(new BagItemDto(item, "Item", item, [], null, packed.Contains(item)));
            }

            // An exam tomorrow, or one whose study days include today.
            foreach (var exam in exams.Where(e => e.ChildId == child.Id && (e.Date == day || e.IsStudyDay(today))))
            {
                var key = $"exam:{exam.Id:N}";
                items.Add(new BagItemDto(key, "Exam", exam.Subject, [], exam.Date, packed.Contains(key)));
            }

            var claim = claims.FirstOrDefault(c => c.ChildId == child.Id);
            bags.Add(new BagDto(child.Id, child.FirstName, day, mine.Select(l => l.Subject).Distinct().ToList(), items, check?.ReadyAt,
                check is { ReadyAt: not null, ReadyByUserId: null }, claim is null ? null : claim.Status == ClaimStatus.Pending ? "Pending" : "Done"));
        }

        return bags;
    }

    /// <summary>What a child's phone shows: today's lessons (the current one marked) and, if allowed, tomorrow's bag.</summary>
    public async Task<ChildSchoolDto?> ChildAsync(Guid familyId, Guid childId, string timeZoneId, CancellationToken ct)
    {
        var now = FamilyTimeZone.ToFamilyTime(clock.GetUtcNow(), timeZoneId);
        var today = DateOnly.FromDateTime(now.DateTime);
        if (!await db.Lessons.AnyAsync(l => l.ChildId == childId, ct))
        {
            return null;
        }

        var plan = await PlanAsync(familyId, ct);
        var breaks = await BreaksAsync(familyId, today, ct);
        var lessons = new List<ChildLessonDto>();
        if (plan.IsSchoolDay(today, breaks))
        {
            var weekday = Lesson.WeekdayOf(today);
            var todays = await db.Lessons.AsNoTracking().Where(l => l.ChildId == childId && l.Weekday == weekday).OrderBy(l => l.Period).ToListAsync(ct);
            var bells = plan.BellTimes;
            var time = TimeOnly.FromDateTime(now.DateTime);
            foreach (var l in todays)
            {
                var start = l.Period <= bells.Count ? TimeOnly.ParseExact(bells[l.Period - 1], "HH:mm") : (TimeOnly?)null;
                var end = l.Period < bells.Count ? TimeOnly.ParseExact(bells[l.Period], "HH:mm") : start?.AddMinutes(40);
                lessons.Add(new ChildLessonDto(l.Period, start?.ToString("HH:mm"), l.Subject, l.Items, start <= time && time < end));
            }
        }

        var bag = plan.ChildPhone ? (await BagsAsync(familyId, plan, breaks, today, [childId], ct)).FirstOrDefault() : null;
        return new ChildSchoolDto(lessons, bag);
    }
}

/// <summary>
/// Ders programı: each child's weekly timetable on the family's bell times, the items lessons need, and the evening
/// "🎒 Yarın çantaya" note before a school day. Parents (and caregivers, for their children) tick the bag and say
/// "Hazırladık"; a child's "Çantam hazır" ticks the same list and asks for one cherry.
/// </summary>
public class SchoolService(
    HallyDbContext db,
    SchoolReader reader,
    ChildModeService childMode,
    NotificationPublisher publisher,
    IHubContext<ChatHub, IChatClient> hub,
    TimeProvider clock,
    ILogger<SchoolService> logger)
{
    public async Task<SchoolDto> GetAsync(Guid familyId, FamilyAccessInfo access, CancellationToken ct)
    {
        var tz = await db.FamilyTimeZoneAsync(familyId, ct);
        var today = FamilyTimeZone.LocalDate(clock.GetUtcNow(), tz);
        var plan = await reader.PlanAsync(familyId, ct);
        var breaks = await reader.BreaksAsync(familyId, today, ct);
        var lessons = (await db.Lessons.AsNoTracking().Where(l => l.FamilyId == familyId).OrderBy(l => l.Weekday).ThenBy(l => l.Period).ToListAsync(ct))
            .Where(l => access.SeesChild(l.ChildId)).ToList();
        var bags = (await reader.BagsAsync(familyId, plan, breaks, today, null, ct)).Where(b => access.SeesChild(b.ChildId)).ToList();
        return new SchoolDto(today, plan.IsSchoolDay(today, breaks), Settings(plan), breaks.Select(b => new SchoolBreakDto(b.Id, b.Title, b.From, b.To)).ToList(),
            lessons.Select(l => new LessonDto(l.Id, l.ChildId, l.Weekday, l.Period, l.Subject, l.Items)).ToList(), bags);
    }

    public async Task<SchoolDto> SaveSettingsAsync(Guid familyId, SchoolSettingsRequest request, FamilyAccessInfo access, CancellationToken ct)
    {
        var plan = await db.SchoolPlans.FirstOrDefaultAsync(p => p.FamilyId == familyId, ct);
        if (plan is null)
        {
            plan = new SchoolPlan(familyId, clock.GetUtcNow());
            db.SchoolPlans.Add(plan);
        }

        TimeOnly? reminder = request.ReminderTime is { } r ? TimeOnly.ParseExact(r, "HH:mm") : null;
        plan.Update(request.BellTimes, request.DailyItems, reminder, request.ChildPhone, request.QuietOnHolidays);
        await SaveAsync(familyId, ct);
        return await GetAsync(familyId, access, ct);
    }

    public async Task<SchoolDto> AddBreakAsync(Guid familyId, SchoolBreakRequest request, FamilyAccessInfo access, CancellationToken ct)
    {
        db.SchoolBreaks.Add(new SchoolBreak(familyId, request.Title, request.From, request.To, clock.GetUtcNow()));
        await SaveAsync(familyId, ct);
        return await GetAsync(familyId, access, ct);
    }

    public async Task<SchoolDto> DeleteBreakAsync(Guid familyId, Guid breakId, FamilyAccessInfo access, CancellationToken ct)
    {
        var item = await db.SchoolBreaks.FirstOrDefaultAsync(b => b.Id == breakId && b.FamilyId == familyId, ct)
                   ?? throw new NotFoundException("school.break_not_found", "Break not found.");
        db.SchoolBreaks.Remove(item);
        await SaveAsync(familyId, ct);
        return await GetAsync(familyId, access, ct);
    }

    public async Task<SchoolDto> SetLessonAsync(Guid familyId, LessonRequest request, FamilyAccessInfo access, CancellationToken ct)
    {
        if (!await db.Children.AnyAsync(c => c.Id == request.ChildId && c.FamilyId == familyId, ct))
        {
            throw new NotFoundException("child.not_found", "Child not found.");
        }

        var lesson = await db.Lessons.FirstOrDefaultAsync(l => l.ChildId == request.ChildId && l.Weekday == request.Weekday && l.Period == request.Period, ct);
        if (string.IsNullOrWhiteSpace(request.Subject))
        {
            if (lesson is not null)
            {
                db.Lessons.Remove(lesson);
            }
        }
        else
        {
            if (lesson is null)
            {
                lesson = new Lesson(familyId, request.ChildId, request.Weekday, request.Period, clock.GetUtcNow());
                db.Lessons.Add(lesson);
            }

            lesson.Set(request.Subject, request.Items);
        }

        await SaveAsync(familyId, ct);
        return await GetAsync(familyId, access, ct);
    }

    /// <summary>Copies one child's whole week to another (siblings in the same class).</summary>
    public async Task<SchoolDto> CopyAsync(Guid familyId, Guid fromChildId, Guid toChildId, FamilyAccessInfo access, CancellationToken ct)
    {
        if (fromChildId == toChildId || await db.Children.CountAsync(c => c.FamilyId == familyId && (c.Id == fromChildId || c.Id == toChildId), ct) != 2)
        {
            throw new NotFoundException("child.not_found", "Child not found.");
        }

        var now = clock.GetUtcNow();
        db.Lessons.RemoveRange(await db.Lessons.Where(l => l.ChildId == toChildId).ToListAsync(ct));
        foreach (var l in await db.Lessons.AsNoTracking().Where(l => l.ChildId == fromChildId).ToListAsync(ct))
        {
            var copy = new Lesson(familyId, toChildId, l.Weekday, l.Period, now);
            copy.Set(l.Subject, l.Items);
            db.Lessons.Add(copy);
        }

        await SaveAsync(familyId, ct);
        return await GetAsync(familyId, access, ct);
    }

    public async Task<SchoolDto> PackAsync(Guid familyId, Guid childId, BagItemRequest request, FamilyAccessInfo access, CancellationToken ct)
    {
        EnsureSees(access, childId);
        var (check, _) = await BagAsync(familyId, childId, ct);
        check.Pack(request.Key, request.Packed);
        await SaveAsync(familyId, ct);
        return await GetAsync(familyId, access, ct);
    }

    /// <summary>"Hazırladık": every item packed; no evening note for this bag.</summary>
    public async Task<SchoolDto> ReadyAsync(Guid familyId, Guid childId, Guid userId, FamilyAccessInfo access, CancellationToken ct)
    {
        EnsureSees(access, childId);
        var (check, bag) = await BagAsync(familyId, childId, ct);
        check.Ready(bag.Items.Select(i => i.Key), userId, clock.GetUtcNow());
        await SaveAsync(familyId, ct);
        return await GetAsync(familyId, access, ct);
    }

    public async Task<ChildSchoolDto?> ChildPackAsync(Guid familyId, Guid childId, BagItemRequest request, CancellationToken ct)
    {
        var (check, _) = await BagAsync(familyId, childId, ct, child: true);
        check.Pack(request.Key, request.Packed);
        await SaveAsync(familyId, ct);
        return await reader.ChildAsync(familyId, childId, await db.FamilyTimeZoneAsync(familyId, ct), ct);
    }

    /// <summary>The child's "Çantam hazır!": the list is ticked at once; the cherry goes through the usual approval.</summary>
    public async Task<ChildSchoolDto?> ChildReadyAsync(Guid familyId, Guid childId, CancellationToken ct)
    {
        var (check, bag) = await BagAsync(familyId, childId, ct, child: true);
        check.Ready(bag.Items.Select(i => i.Key), null, clock.GetUtcNow());
        await SaveAsync(familyId, ct);
        await childMode.MarkDoneAsync(familyId, childId, ClaimKind.Bag, childId, ct);
        return await reader.ChildAsync(familyId, childId, await db.FamilyTimeZoneAsync(familyId, ct), ct);
    }

    /// <summary>
    /// Every 15 minutes: once the family's reminder time has passed, each parent gets one "🎒 Yarın çantaya" per child
    /// with lessons tomorrow, unless that bag is already ready. Nothing before weekends, breaks and (when chosen)
    /// official holidays.
    /// </summary>
    public async Task<int> EveningAsync(CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        var familyIds = await db.Lessons.AsNoTracking().Select(l => l.FamilyId).Distinct().ToListAsync(ct);
        if (familyIds.Count == 0)
        {
            return 0;
        }

        var zones = await db.Families.AsNoTracking().Where(f => familyIds.Contains(f.Id)).ToDictionaryAsync(f => f.Id, f => f.TimeZoneId, ct);
        var added = 0;
        foreach (var familyId in familyIds)
        {
            var local = FamilyTimeZone.ToFamilyTime(now, zones[familyId]);
            var plan = await reader.PlanAsync(familyId, ct);
            if (plan.ReminderTime is not { } at || TimeOnly.FromDateTime(local.DateTime) < at)
            {
                continue;
            }

            var today = DateOnly.FromDateTime(local.DateTime);
            var breaks = await reader.BreaksAsync(familyId, today, ct);
            var bags = (await reader.BagsAsync(familyId, plan, breaks, today, null, ct)).Where(b => b.ReadyAt is null).ToList();
            if (bags.Count == 0)
            {
                continue;
            }

            var parents = await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == familyId && m.Role != FamilyRole.Caregiver)
                .Join(db.Users.AsNoTracking(), m => m.UserId, u => u.Id, (m, u) => new { u.Id, u.Locale }).ToListAsync(ct);
            var lessons = await db.Lessons.AsNoTracking().Where(l => l.FamilyId == familyId && l.Weekday == Lesson.WeekdayOf(today.AddDays(1))).ToListAsync(ct);
            foreach (var bag in bags)
            {
                foreach (var p in parents)
                {
                    var (title, body) = SchoolTexts.Bag(p.Locale != "en", bag, lessons.Where(l => l.ChildId == bag.ChildId).OrderBy(l => l.Period).ToList(), plan.DailyItems);
                    if (await publisher.AddAsync(p.Id, familyId, NotificationKind.SchoolBag, title, body, null, bag.ChildId, $"school-bag:{bag.ChildId:N}:{bag.Day:yyyyMMdd}:{p.Id:N}", ct))
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

    private static void EnsureSees(FamilyAccessInfo access, Guid childId)
    {
        if (!access.SeesChild(childId))
        {
            throw new NotFoundException("child.not_found", "Child not found.");
        }
    }

    /// <summary>Tomorrow's bag check for the child (created on first use); fails when there is no school tomorrow.</summary>
    private async Task<(BagCheck Check, BagDto Bag)> BagAsync(Guid familyId, Guid childId, CancellationToken ct, bool child = false)
    {
        var tz = await db.FamilyTimeZoneAsync(familyId, ct);
        var today = FamilyTimeZone.LocalDate(clock.GetUtcNow(), tz);
        var plan = await reader.PlanAsync(familyId, ct);
        if (child && !plan.ChildPhone)
        {
            throw new DomainException("school.child_phone_off", "The bag list is not shown on this phone.");
        }

        var breaks = await reader.BreaksAsync(familyId, today, ct);
        var bag = (await reader.BagsAsync(familyId, plan, breaks, today, [childId], ct)).FirstOrDefault()
                  ?? throw new DomainException("school.no_school_tomorrow", "No lessons tomorrow.");
        var check = await db.BagChecks.FirstOrDefaultAsync(b => b.ChildId == childId && b.Day == bag.Day, ct);
        if (check is null)
        {
            check = new BagCheck(familyId, childId, bag.Day, clock.GetUtcNow());
            db.BagChecks.Add(check);
        }

        return (check, bag);
    }

    private async Task SaveAsync(Guid familyId, CancellationToken ct)
    {
        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (DbUpdateException)
        {
            // Two taps at once: the unique indexes kept one; the reload shows it.
            db.ChangeTracker.Clear();
        }

        try
        {
            var members = await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == familyId).Select(m => m.UserId).ToListAsync(ct);
            await hub.Clients.Groups(members.Select(ChatHub.UserGroup).ToList()).SchoolChanged(new SchoolEvent(familyId));
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Realtime school event failed");
        }
    }

    private static SchoolSettingsDto Settings(SchoolPlan plan) =>
        new(plan.BellTimes, plan.DailyItems, plan.ReminderTime?.ToString("HH:mm"), plan.ChildPhone, plan.QuietOnHolidays);
}

public static class SchoolTexts
{
    /// <summary>"🎒 Yarın çantaya · Ela" / "Beden Eğitimi: 👟 Eşofman. Resim: 🎨 Boya kalemi. Her gün: 🍎 Beslenme."</summary>
    public static (string Title, string Body) Bag(bool tr, BagDto bag, IReadOnlyList<Lesson> lessons, IReadOnlyList<string> daily)
    {
        var parts = lessons.Where(l => l.Items.Count > 0).GroupBy(l => l.Subject)
            .Select(g => $"{g.Key}: {string.Join(", ", g.SelectMany(l => l.Items).Distinct())}").ToList();
        if (daily.Count > 0)
        {
            parts.Add((tr ? "Her gün: " : "Every day: ") + string.Join(", ", daily));
        }

        foreach (var exam in bag.Items.Where(i => i.Kind == "Exam"))
        {
            var days = exam.ExamDate!.Value.DayNumber - bag.Day.DayNumber;
            parts.Add(tr
                ? days == 0 ? $"📝 {exam.Text} sınavı yarın" : $"📝 {exam.Text} sınavına {days + 1} gün var"
                : days == 0 ? $"📝 {exam.Text} exam tomorrow" : $"📝 {exam.Text} exam in {days + 1} days");
        }

        if (parts.Count == 0)
        {
            parts.Add((tr ? "Yarınki dersler: " : "Tomorrow's lessons: ") + string.Join(", ", bag.Subjects));
        }

        return (tr ? $"🎒 Yarın çantaya · {bag.ChildName}" : $"🎒 Pack for tomorrow · {bag.ChildName}", string.Join(". ", parts) + ".");
    }
}

/// <summary>Parents set up the timetable; caregivers see it for their children and help pack.</summary>
[ApiController]
[Authorize(Policy = Policies.FamilyMember)]
[Route("api/v1/families/{familyId:guid}/school")]
public class SchoolController(SchoolService school) : ControllerBase
{
    [CaregiverAllowed]
    [HttpGet]
    public Task<SchoolDto> Get(Guid familyId, CancellationToken ct) => school.GetAsync(familyId, HttpContext.Access(), ct);

    [HttpPut("settings")]
    public Task<SchoolDto> Settings(Guid familyId, SchoolSettingsRequest request, CancellationToken ct) =>
        school.SaveSettingsAsync(familyId, request, HttpContext.Access(), ct);

    [HttpPost("breaks")]
    public Task<SchoolDto> AddBreak(Guid familyId, SchoolBreakRequest request, CancellationToken ct) =>
        school.AddBreakAsync(familyId, request, HttpContext.Access(), ct);

    [HttpDelete("breaks/{breakId:guid}")]
    public Task<SchoolDto> DeleteBreak(Guid familyId, Guid breakId, CancellationToken ct) =>
        school.DeleteBreakAsync(familyId, breakId, HttpContext.Access(), ct);

    [HttpPut("lessons")]
    public Task<SchoolDto> Lesson(Guid familyId, LessonRequest request, CancellationToken ct) =>
        school.SetLessonAsync(familyId, request, HttpContext.Access(), ct);

    [HttpPost("children/{childId:guid}/copy-from/{fromChildId:guid}")]
    public Task<SchoolDto> Copy(Guid familyId, Guid childId, Guid fromChildId, CancellationToken ct) =>
        school.CopyAsync(familyId, fromChildId, childId, HttpContext.Access(), ct);

    [CaregiverAllowed]
    [HttpPut("bags/{childId:guid}/items")]
    public Task<SchoolDto> Pack(Guid familyId, Guid childId, BagItemRequest request, CancellationToken ct) =>
        school.PackAsync(familyId, childId, request, HttpContext.Access(), ct);

    [CaregiverAllowed]
    [HttpPost("bags/{childId:guid}/ready")]
    public Task<SchoolDto> Ready(Guid familyId, Guid childId, CancellationToken ct) =>
        school.ReadyAsync(familyId, childId, User.UserId(), HttpContext.Access(), ct);
}

/// <summary>The child's phone: tick tomorrow's bag and say "Çantam hazır!".</summary>
[ApiController]
[Authorize(Policy = ChildDeviceAuth.Policy)]
[Route("api/v1/child/school/bag")]
public class ChildSchoolController(SchoolService school) : ControllerBase
{
    [HttpPut("items")]
    public Task<ChildSchoolDto?> Pack(BagItemRequest request, CancellationToken ct) =>
        school.ChildPackAsync(User.ChildFamilyId(), User.ChildId(), request, ct);

    [HttpPost("ready")]
    public Task<ChildSchoolDto?> Ready(CancellationToken ct) => school.ChildReadyAsync(User.ChildFamilyId(), User.ChildId(), ct);
}
