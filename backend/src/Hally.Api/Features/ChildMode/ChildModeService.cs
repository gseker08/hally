using Hally.Api.Common;
using Hally.Api.Features.Messages;
using Hally.Api.Features.Notifications;
using Hally.Api.Features.Points;
using Hally.Api.Features.ScreenTime;
using Hally.Domain.Activities;
using Hally.Domain.ChildMode;
using Hally.Domain.Common;
using Hally.Domain.Families;
using Hally.Domain.Habits;
using Hally.Domain.Notifications;
using Hally.Domain.Points;
using Hally.Domain.Users;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.ChildMode;

public record ChildProfileDto(Guid Id, string FirstName, string Color, bool HasPhoto);

/// <param name="Kind">Chore or Habit.</param>
/// <param name="State">Todo, Pending (waits for a parent) or Done.</param>
public record ChildItemDto(Guid Id, string Kind, string Title, int Cherries, string State);

public record ChildRewardDto(Guid Id, string Title, int Cost, int? ScreenMinutes);

/// <summary>Today's screen time on the child's phone.</summary>
/// <param name="GoalMinutes">The parents' daily limit; null means no limit (never locks).</param>
/// <param name="LimitMinutes">Goal plus today's extra minutes; null without a goal.</param>
/// <param name="UsedSeconds">What the child's phone measured today.</param>
/// <param name="Bedtime">Locked because the bedtime routine is done (until the morning), not because time ran out.</param>
public record ChildScreenDto(DateOnly Day, int? GoalMinutes, int BonusMinutes, int? LimitMinutes, int UsedSeconds, bool Locked, bool Bedtime = false);

/// <param name="NextBonusIn">Days still needed for the next streak bonus.</param>
public record ChildHomeDto(
    ChildProfileDto Child,
    string FamilyName,
    int Balance,
    int WeekCherries,
    int StreakDays,
    int NextBonusIn,
    bool RequireApproval,
    IReadOnlyList<ChildItemDto> Today,
    IReadOnlyList<ChildRewardDto> Rewards,
    ChildScreenDto Screen,
    string? TodayMood = null,
    Hally.Api.Features.Bedtime.ChildBedtimeDto? Bedtime = null,
    IReadOnlyList<Hally.Api.Features.Exams.ChildExamDto>? Exams = null,
    Hally.Api.Features.School.ChildSchoolDto? School = null);

public record ClaimDto(Guid Id, Guid ChildId, string ChildName, string Kind, string Title, int Cherries, DateOnly Day, DateTimeOffset At);

/// <summary>
/// Child mode: what a paired child phone sees and does (today's chores and habits, the cherry jar, rewards, screen
/// time) and the parent side of it (approvals, extra minutes). Cherries are the same ledger as the parents' chore
/// board (<see cref="PointEntry"/>).
/// </summary>
public class ChildModeService(
    HallyDbContext db,
    NotificationPublisher publisher,
    IHubContext<ChatHub, IChatClient> hub,
    TimeProvider clock,
    Hally.Api.Features.Bedtime.BedtimeService bedtime,
    Hally.Api.Features.School.SchoolReader school,
    ILogger<ChildModeService> logger)
{
    public async Task<ChildHomeDto> HomeAsync(Guid familyId, Guid childId, CancellationToken ct)
    {
        var family = await db.Families.AsNoTracking().FirstAsync(f => f.Id == familyId, ct);
        var child = await db.Children.AsNoTracking().FirstAsync(c => c.Id == childId && c.FamilyId == familyId, ct);
        var today = FamilyTimeZone.LocalDate(clock.GetUtcNow(), family.TimeZoneId);
        var weekStart = today.AddDays(-(((int)today.DayOfWeek + 6) % 7));

        var entries = await db.PointEntries.AsNoTracking().Where(p => p.ChildId == childId)
            .Select(p => new { p.Kind, p.Points, p.Day, p.ChoreId, p.HabitId }).ToListAsync(ct);
        var balance = entries.Sum(e => e.Points);
        var week = entries.Where(e => e.Points > 0 && e.Kind != PointKind.Allowance && e.Day >= weekStart).Sum(e => e.Points);
        var streak = CherryStreak.Length(ActiveDays(entries.Select(e => (e.Kind, e.Points, e.Day))), today);

        var pending = await db.ChildClaims.AsNoTracking()
            .Where(c => c.ChildId == childId && c.Day == today && c.Status == ClaimStatus.Pending).Select(c => c.ItemId).ToListAsync(ct);
        var choresDone = entries.Where(e => e.Day == today && e.ChoreId != null).Select(e => e.ChoreId!.Value).ToHashSet();
        var habitsDone = await db.HabitChecks.AsNoTracking().Where(h => h.FamilyId == familyId && h.Day == today).Select(h => h.HabitId).ToListAsync(ct);

        string State(Guid id, bool done) => done ? "Done" : pending.Contains(id) ? "Pending" : "Todo";

        var chores = await db.Chores.AsNoTracking().Where(c => c.FamilyId == familyId && (c.ChildId == null || c.ChildId == childId))
            .OrderBy(c => c.CreatedAt).ToListAsync(ct);
        var habits = (await db.Habits.AsNoTracking().Where(h => h.ChildId == childId).OrderBy(h => h.CreatedAt).ToListAsync(ct))
            .Where(h => h.IsScheduled(today));
        var items = chores.Select(c => new ChildItemDto(c.Id, "Chore", c.Title, c.Points, State(c.Id, choresDone.Contains(c.Id))))
            .Concat(habits.Select(h => new ChildItemDto(h.Id, "Habit", h.Title, 1, State(h.Id, habitsDone.Contains(h.Id)))))
            .ToList();
        var rewards = await db.Rewards.AsNoTracking().Where(r => r.FamilyId == familyId).OrderBy(r => r.Cost)
            .Select(r => new ChildRewardDto(r.Id, r.Title, r.Cost, r.ScreenMinutes)).ToListAsync(ct);

        return new ChildHomeDto(
            new ChildProfileDto(child.Id, child.FirstName, child.Color, child.PhotoKey is not null),
            family.Name, balance, week, streak, CherryStreak.BonusEvery - streak % CherryStreak.BonusEvery,
            family.RequireChildApproval, items, rewards, await ScreenAsync(child, today, ct),
            (await db.MoodChecks.AsNoTracking().Where(m => m.ChildId == childId && m.Day == today).Select(m => (Hally.Domain.Mood.Mood?)m.Mood).FirstOrDefaultAsync(ct))?.ToString(),
            await bedtime.ChildAsync(childId, family.TimeZoneId, ct),
            await ExamsAsync(childId, today, ct),
            await school.ChildAsync(familyId, childId, family.TimeZoneId, ct));
    }

    /// <summary>The child says "Yaptım!". With approval on it waits for a parent, otherwise the cherries land at once.
    /// Doing it twice, or something already ticked by a parent, changes nothing.</summary>
    /// <param name="turkish">For a built-in screen-free idea: which language its title is saved in.</param>
    public async Task MarkDoneAsync(Guid familyId, Guid childId, ClaimKind kind, Guid itemId, CancellationToken ct, bool turkish = true)
    {
        var family = await db.Families.AsNoTracking().FirstAsync(f => f.Id == familyId, ct);
        var now = clock.GetUtcNow();
        var today = FamilyTimeZone.LocalDate(now, family.TimeZoneId);
        string title;
        int points;
        if (kind == ClaimKind.Chore)
        {
            var chore = await db.Chores.AsNoTracking().FirstOrDefaultAsync(c => c.Id == itemId && c.FamilyId == familyId && (c.ChildId == null || c.ChildId == childId), ct)
                        ?? throw new NotFoundException("chore.not_found", "Chore not found.");
            if (await db.PointEntries.AnyAsync(p => p.ChoreId == itemId && p.ChildId == childId && p.Day == today, ct))
            {
                return;
            }

            (title, points) = (chore.Title, chore.Points);
        }
        else if (kind == ClaimKind.Study)
        {
            var exam = await db.Exams.AsNoTracking().FirstOrDefaultAsync(e => e.Id == itemId && e.ChildId == childId && e.FamilyId == familyId, ct)
                       ?? throw new NotFoundException("exam.not_found", "Exam not found.");
            if (exam.Date < today)
            {
                throw new DomainException("exam.past", "This exam is over.");
            }

            (title, points) = (exam.Subject, StudyCherries);
        }
        else if (kind == ClaimKind.Bag)
        {
            (title, points) = (turkish ? "🎒 Çantam hazır" : "🎒 Bag packed", BagCherries);
        }
        else if (kind == ClaimKind.Activity)
        {
            if (ActivityCatalog.Find(itemId) is { } idea)
            {
                (title, points) = (idea.Title(turkish), idea.Cherries);
            }
            else
            {
                var own = await db.FamilyActivities.AsNoTracking().FirstOrDefaultAsync(a => a.Id == itemId && a.FamilyId == familyId, ct)
                          ?? throw new NotFoundException("activity.not_found", "Idea not found.");
                (title, points) = (own.Title, own.Cherries);
            }

            if (await db.ChildClaims.CountAsync(c => c.ChildId == childId && c.Kind == ClaimKind.Activity && c.Day == today && c.Status != ClaimStatus.Rejected, ct)
                >= ActivityCatalog.DailyLimit
                && !await db.ChildClaims.AnyAsync(c => c.ChildId == childId && c.ItemId == itemId && c.Day == today && c.Status != ClaimStatus.Rejected, ct))
            {
                throw new DomainException("activity.daily_limit", $"At most {ActivityCatalog.DailyLimit} ideas a day.");
            }
        }
        else
        {
            var habit = await db.Habits.AsNoTracking().FirstOrDefaultAsync(h => h.Id == itemId && h.ChildId == childId, ct)
                        ?? throw new NotFoundException("habit.not_found", "Habit not found.");
            if (!habit.IsScheduled(today))
            {
                throw new DomainException("habit.not_today", "This habit is not for today.");
            }

            if (await db.HabitChecks.AnyAsync(h => h.HabitId == itemId && h.Day == today, ct))
            {
                return;
            }

            (title, points) = (habit.Title, 1);
        }

        if (await db.ChildClaims.AnyAsync(c => c.ChildId == childId && c.ItemId == itemId && c.Day == today && c.Status != ClaimStatus.Rejected, ct))
        {
            return;
        }

        var claim = new ChildClaim(familyId, childId, kind, itemId, title, points, today, now);
        db.ChildClaims.Add(claim);
        if (!family.RequireChildApproval)
        {
            claim.Decide(true, null, now);
            await CreditAsync(claim, null, today, now, ct);
        }

        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (DbUpdateException)
        {
            // A double tap or a parent ticking it at the same moment: the unique indexes kept one.
            db.ChangeTracker.Clear();
            return;
        }

        if (family.RequireChildApproval)
        {
            await NotifyParentsAsync(familyId, NotificationKind.ChildClaim, childId,
                (tr, name) => tr ? ($"{name}: {title} ✓", $"Onaylarsan {points} kiraz kazanacak.") : ($"{name}: {title} ✓", $"Approve it to give {points} cherries."),
                $"claim:{claim.Id:N}", ct);
        }

        await AnnounceAsync(familyId, ct);
    }

    /// <summary>Cherries for one approved "Çalıştım" before an exam.</summary>
    public const int StudyCherries = 1;

    /// <summary>Cherries for an approved "Çantam hazır".</summary>
    public const int BagCherries = 1;

    private async Task<IReadOnlyList<Hally.Api.Features.Exams.ChildExamDto>> ExamsAsync(Guid childId, DateOnly today, CancellationToken ct)
    {
        var until = today.AddDays(Hally.Api.Features.Exams.ExamService.ChildAheadDays);
        var exams = await db.Exams.AsNoTracking().Where(e => e.ChildId == childId && e.Date >= today && e.Date <= until)
            .OrderBy(e => e.Date).ThenBy(e => e.CreatedAt).ToListAsync(ct);
        if (exams.Count == 0)
        {
            return [];
        }

        var ids = exams.Select(e => e.Id).ToList();
        var now = clock.GetUtcNow();
        var sessions = await db.StudySessions.AsNoTracking().Where(s => s.ExamId != null && ids.Contains(s.ExamId.Value)).ToListAsync(ct);
        var claims = await db.ChildClaims.AsNoTracking()
            .Where(c => c.ChildId == childId && c.Kind == ClaimKind.Study && c.Day == today && ids.Contains(c.ItemId) && c.Status != ClaimStatus.Rejected)
            .Select(c => new { c.ItemId, c.Status }).ToListAsync(ct);
        return exams.Select(e =>
        {
            var claim = claims.FirstOrDefault(c => c.ItemId == e.Id);
            var seconds = (int)sessions.Where(s => s.ExamId == e.Id).Sum(s => (s.CountsUntil(now) - s.StartedAt).TotalSeconds);
            return new Hally.Api.Features.Exams.ChildExamDto(e.Id, e.Subject, e.Topics, e.Date, e.Slot, e.Date.DayNumber - today.DayNumber, seconds,
                claim is null ? "Todo" : claim.Status == ClaimStatus.Pending ? "Pending" : "Done");
        }).ToList();
    }

    public async Task<IReadOnlyList<ClaimDto>> PendingAsync(Guid familyId, CancellationToken ct)
    {
        return await db.ChildClaims.AsNoTracking().Where(c => c.FamilyId == familyId && c.Status == ClaimStatus.Pending)
            .OrderBy(c => c.CreatedAt)
            .Join(db.Children.AsNoTracking(), c => c.ChildId, ch => ch.Id,
                (c, ch) => new ClaimDto(c.Id, c.ChildId, ch.FirstName, c.Kind.ToString(), c.Title, c.Points, c.Day, c.CreatedAt))
            .ToListAsync(ct);
    }

    public async Task DecideAsync(Guid familyId, Guid claimId, bool approve, Guid userId, CancellationToken ct)
    {
        var claim = await db.ChildClaims.FirstOrDefaultAsync(c => c.Id == claimId && c.FamilyId == familyId, ct)
                    ?? throw new NotFoundException("claim.not_found", "Not found.");
        var now = clock.GetUtcNow();
        claim.Decide(approve, userId, now);
        if (approve)
        {
            var tz = await db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.TimeZoneId).FirstAsync(ct);
            await CreditAsync(claim, userId, FamilyTimeZone.LocalDate(now, tz), now, ct);
        }

        await db.SaveChangesAsync(ct);
        await AnnounceAsync(familyId, ct);
    }

    /// <summary>Spends cherries. An extra-screen-time reward adds its minutes to today's limit at once; parents get a
    /// note either way (an outing or pocket money is theirs to hand over).</summary>
    public async Task RedeemAsync(Guid familyId, Guid childId, Guid rewardId, CancellationToken ct)
    {
        var reward = await db.Rewards.FirstOrDefaultAsync(r => r.Id == rewardId && r.FamilyId == familyId, ct)
                     ?? throw new NotFoundException("reward.not_found", "Reward not found.");
        var tz = await db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.TimeZoneId).FirstAsync(ct);
        var now = clock.GetUtcNow();
        var today = FamilyTimeZone.LocalDate(now, tz);
        await using (var tx = await db.Database.BeginTransactionAsync(System.Data.IsolationLevel.Serializable, ct))
        {
            var balance = await db.PointEntries.Where(p => p.ChildId == childId).SumAsync(p => p.Points, ct);
            db.PointEntries.Add(PointEntry.ForReward(reward, childId, balance, null, today, now));
            if (reward.ScreenMinutes is { } minutes)
            {
                db.ScreenBonuses.Add(new ScreenBonus(familyId, childId, today, minutes, BonusSource.Reward, null, now));
            }

            await db.SaveChangesAsync(ct);
            await tx.CommitAsync(ct);
        }

        await NotifyParentsAsync(familyId, NotificationKind.ChildReward, childId,
            (tr, name) => reward.ScreenMinutes is { } m
                ? tr ? ($"{name}: +{m} dk ekran", $"{reward.Cost} kirazla \"{reward.Title}\" aldı.") : ($"{name}: +{m} min screen time", $"Spent {reward.Cost} cherries on \"{reward.Title}\".")
                : tr ? ($"{name}: {reward.Title}", $"{reward.Cost} kiraz harcadı. Ödülünü vermeyi unutma.") : ($"{name}: {reward.Title}", $"Spent {reward.Cost} cherries. Don't forget to hand it over."),
            $"redeem:{Guid.NewGuid():N}", ct);
        await AnnounceAsync(familyId, ct);
    }

    /// <summary>The child's phone reports today's measured screen time. The first report at or over the limit tells
    /// the parents that the phone locked.</summary>
    public async Task<ChildScreenDto> ReportUsageAsync(Guid familyId, Guid childId, int seconds, CancellationToken ct)
    {
        var child = await db.Children.AsNoTracking().FirstAsync(c => c.Id == childId && c.FamilyId == familyId, ct);
        var tz = await db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.TimeZoneId).FirstAsync(ct);
        var now = clock.GetUtcNow();
        var today = FamilyTimeZone.LocalDate(now, tz);
        var usage = await db.ScreenUsages.FirstOrDefaultAsync(u => u.ChildId == childId && u.Day == today, ct);
        if (usage is null)
        {
            usage = new ScreenUsage(familyId, childId, today, now);
            db.ScreenUsages.Add(usage);
        }

        usage.Report(seconds, now);
        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (DbUpdateException)
        {
            // Two reports raced to create today's row; the next report updates it.
            db.ChangeTracker.Clear();
        }

        var screen = await ScreenAsync(child, today, ct);
        if (screen.Locked)
        {
            await NotifyParentsAsync(familyId, NotificationKind.ScreenTimeGoal, childId,
                (tr, name) => tr ? ($"{name}: ekran süresi doldu", "Telefonu kilitlendi. Ek süre vermek istersen Hally'den verebilirsin.")
                    : ($"{name}: screen time is up", "Their phone is locked. You can give extra time in Hally."),
                $"lock:{childId:N}:{today:yyyyMMdd}:{screen.LimitMinutes}", ct);
        }

        return screen;
    }

    public async Task<ChildScreenDto> GrantAsync(Guid familyId, Guid childId, int minutes, Guid userId, CancellationToken ct)
    {
        var child = await db.Children.AsNoTracking().FirstOrDefaultAsync(c => c.Id == childId && c.FamilyId == familyId, ct)
                    ?? throw new NotFoundException("child.not_found", "Child not found.");
        var tz = await db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.TimeZoneId).FirstAsync(ct);
        var now = clock.GetUtcNow();
        var today = FamilyTimeZone.LocalDate(now, tz);
        db.ScreenBonuses.Add(new ScreenBonus(familyId, childId, today, minutes, BonusSource.Parent, userId, now));
        await db.SaveChangesAsync(ct);
        return await ScreenAsync(child, today, ct);
    }

    public async Task<ChildScreenDto> ScreenAsync(Guid familyId, Guid childId, CancellationToken ct)
    {
        var child = await db.Children.AsNoTracking().FirstOrDefaultAsync(c => c.Id == childId && c.FamilyId == familyId, ct)
                    ?? throw new NotFoundException("child.not_found", "Child not found.");
        var tz = await db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.TimeZoneId).FirstAsync(ct);
        return await ScreenAsync(child, FamilyTimeZone.LocalDate(clock.GetUtcNow(), tz), ct);
    }

    private async Task<ChildScreenDto> ScreenAsync(Child child, DateOnly today, CancellationToken ct)
    {
        var used = await db.ScreenUsages.AsNoTracking().Where(u => u.ChildId == child.Id && u.Day == today).Select(u => u.Seconds).FirstOrDefaultAsync(ct);
        var bonus = await db.ScreenBonuses.AsNoTracking().Where(b => b.ChildId == child.Id && b.Day == today).SumAsync(b => b.Minutes, ct);
        int? limit = child.DailyScreenMinutes is { } goal ? goal + bonus : null;
        var tz = await db.Families.AsNoTracking().Where(f => f.Id == child.FamilyId).Select(f => f.TimeZoneId).FirstAsync(ct);
        var night = await bedtime.NightLockedAsync(child.Id, tz, ct);
        return new ChildScreenDto(today, child.DailyScreenMinutes, bonus, limit, used, night || (limit is { } l && used >= l * 60), night);
    }

    /// <summary>Adds the claim's cherries (and the habit tick) unless a parent already ticked it, then the streak bonus
    /// when today completes seven days in a row. Caller saves.</summary>
    private async Task CreditAsync(ChildClaim claim, Guid? userId, DateOnly today, DateTimeOffset now, CancellationToken ct)
    {
        if (claim.Kind == ClaimKind.Study)
        {
            db.PointEntries.Add(PointEntry.ForExam(claim.FamilyId, claim.ChildId, claim.Title, claim.Points, userId, claim.Day, now));
            return;
        }

        if (claim.Kind == ClaimKind.Bag)
        {
            db.PointEntries.Add(PointEntry.ForBag(claim.FamilyId, claim.ChildId, claim.Points, userId, claim.Day, now));
            return;
        }

        if (claim.Kind == ClaimKind.Activity)
        {
            db.PointEntries.Add(PointEntry.ForActivity(claim.FamilyId, claim.ChildId, claim.Title, claim.Points, userId, claim.Day, now));
        }
        else if (claim.Kind == ClaimKind.Chore)
        {
            if (!await db.PointEntries.AnyAsync(p => p.ChoreId == claim.ItemId && p.ChildId == claim.ChildId && p.Day == claim.Day, ct))
            {
                var exists = await db.Chores.AnyAsync(c => c.Id == claim.ItemId, ct);
                db.PointEntries.Add(PointEntry.ForChoreClaim(claim.FamilyId, claim.ChildId, exists ? claim.ItemId : null, claim.Title, claim.Points, userId, claim.Day, now));
            }
        }
        else
        {
            var habit = await db.Habits.FirstOrDefaultAsync(h => h.Id == claim.ItemId, ct);
            if (habit is not null && !await db.HabitChecks.AnyAsync(h => h.HabitId == habit.Id && h.Day == claim.Day, ct))
            {
                db.HabitChecks.Add(new HabitCheck(habit, claim.Day, userId, now));
            }

            if (habit is null || !await db.PointEntries.AnyAsync(p => p.HabitId == habit.Id && p.Day == claim.Day, ct))
            {
                db.PointEntries.Add(PointEntry.ForHabit(claim.FamilyId, claim.ChildId, habit?.Id, claim.Title, userId, claim.Day, now));
            }
        }

        // The streak counts days with cherries earned, including the one being added now.
        var since = today.AddDays(-400);
        var earned = await db.PointEntries.AsNoTracking()
            .Where(p => p.ChildId == claim.ChildId && p.Day >= since && (p.Kind == PointKind.Chore || p.Kind == PointKind.Habit || p.Kind == PointKind.Activity) && p.Points > 0)
            .Select(p => p.Day).Distinct().ToListAsync(ct);
        var days = earned.ToHashSet();
        days.Add(claim.Day);
        var streak = CherryStreak.Length(days, today);
        if (streak > 0 && streak % CherryStreak.BonusEvery == 0
            && !await db.PointEntries.AnyAsync(p => p.ChildId == claim.ChildId && p.Kind == PointKind.Bonus && p.Day == today, ct)
            && !db.ChangeTracker.Entries<PointEntry>().Any(x => x.Entity.ChildId == claim.ChildId && x.Entity.Kind == PointKind.Bonus))
        {
            db.PointEntries.Add(PointEntry.ForStreakBonus(claim.FamilyId, claim.ChildId, streak, today, now));
        }
    }

    private static HashSet<DateOnly> ActiveDays(IEnumerable<(PointKind Kind, int Points, DateOnly Day)> entries) =>
        entries.Where(e => e.Points > 0 && e.Kind is PointKind.Chore or PointKind.Habit or PointKind.Activity).Select(e => e.Day).ToHashSet();

    /// <summary>Tells the parents that a child's phone left child mode with their PIN.</summary>
    public Task DeviceExitedAsync(ChildDevice device, CancellationToken ct) =>
        NotifyParentsAsync(device.FamilyId, NotificationKind.ChildDeviceExited, device.ChildId,
            (tr, name) => tr
                ? ($"{name}: telefon çocuk modundan çıktı", "Ebeveyn PIN'i girildi ve telefonun bağlantısı kaldırıldı. Tekrar bağlamak için Aile → Telefon ekranından yeni kod alın.")
                : ($"{name}: phone left child mode", "The parent PIN was entered and the phone was unpaired. To pair it again, get a new code from Family → Phone."),
            $"child-exit:{device.Id:N}", ct);

    /// <summary>One inbox entry (and push) per parent; caregivers are not asked. Best effort.</summary>
    private async Task NotifyParentsAsync(Guid familyId, NotificationKind kind, Guid childId,
        Func<bool, string, (string Title, string Body)> text, string dedup, CancellationToken ct)
    {
        try
        {
            var name = await db.Children.AsNoTracking().Where(c => c.Id == childId).Select(c => c.FirstName).FirstAsync(ct);
            var parents = await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == familyId && m.Role != FamilyRole.Caregiver)
                .Join(db.Users.AsNoTracking(), m => m.UserId, u => u.Id, (m, u) => new { u.Id, u.Locale }).ToListAsync(ct);
            var added = false;
            foreach (var p in parents)
            {
                var (title, body) = text(Locales.IsTurkish(p.Locale), name);
                added |= await publisher.AddAsync(p.Id, familyId, kind, title, body, null, childId, $"{dedup}:{p.Id:N}", ct);
            }

            if (added)
            {
                await db.SaveChangesAsync(ct);
                await publisher.FlushPushAsync(ct);
            }
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Child mode notification failed");
        }
    }

    private async Task AnnounceAsync(Guid familyId, CancellationToken ct)
    {
        try
        {
            var members = await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == familyId).Select(m => m.UserId).ToListAsync(ct);
            await hub.Clients.Groups(members.Select(ChatHub.UserGroup).ToList()).PointsChanged(new PointsEvent(familyId));
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Realtime points event failed");
        }
    }
}
