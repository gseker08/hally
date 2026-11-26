using Hally.Api.Auth;
using Hally.Api.Common;
using Hally.Api.Features.Notifications;
using Hally.Domain.Common;
using Hally.Domain.Families;
using Hally.Domain.Goals;
using Hally.Domain.Notifications;
using Hally.Domain.Points;
using Hally.Domain.Users;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.Goals;

/// <param name="Kind">Child or Adult.</param>
/// <param name="Color">A child's colour key; null for adults.</param>
public record GoalContributorDto(string Kind, Guid Id, string Name, string? Color, int Cherries);

/// <summary>This week's goal. Contributors are listed children first, then parents, in the order they joined the
/// family: never ranked.</summary>
public record FamilyGoalDto(
    Guid Id,
    DateOnly WeekStart,
    DateOnly WeekEnd,
    int DaysLeft,
    string RewardTitle,
    string RewardEmoji,
    int Target,
    int Total,
    bool Repeat,
    DateTimeOffset? ReachedAt,
    IReadOnlyList<GoalContributorDto> Contributors);

/// <param name="Goal">Null when no goal runs this week.</param>
/// <param name="LastWeekTotal">What the family collected last week (for the suggestion).</param>
/// <param name="SuggestedTarget">A reachable target: a bit above last week, rounded to 10.</param>
public record FamilyGoalStateDto(DateOnly Today, FamilyGoalDto? Goal, int LastWeekTotal, int SuggestedTarget);

public record FamilyGoalRequest(string RewardTitle, string RewardEmoji, int Target, bool Repeat);

/// <summary>Builds the weekly goal, starts a repeating one on Monday and announces it when reached.</summary>
public class FamilyGoalService(HallyDbContext db, NotificationPublisher publisher, TimeProvider clock, ILogger<FamilyGoalService> logger)
{
    public const int DefaultTarget = 80;

    public async Task<FamilyGoalStateDto> StateAsync(Guid familyId, CancellationToken ct)
    {
        var tz = await db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.TimeZoneId).FirstAsync(ct);
        var today = FamilyTimeZone.LocalDate(clock.GetUtcNow(), tz);
        var week = FamilyGoal.WeekOf(today);
        var goal = await CurrentAsync(familyId, week, ct);
        var lastWeek = (await ContributorsAsync(familyId, week.AddDays(-7), tz, ct)).Sum(c => c.Cherries);
        var suggested = lastWeek == 0 ? DefaultTarget : Math.Clamp((int)Math.Round(lastWeek * 1.15 / 10.0) * 10, FamilyGoal.MinTarget, FamilyGoal.MaxTarget);

        FamilyGoalDto? dto = null;
        if (goal is not null)
        {
            var contributors = await ContributorsAsync(familyId, week, tz, ct);
            var total = contributors.Sum(c => c.Cherries);
            if (goal.CheckReached(total, clock.GetUtcNow()))
            {
                await AnnounceAsync(goal, total, ct);
            }

            await db.SaveChangesAsync(ct);
            dto = new FamilyGoalDto(goal.Id, goal.WeekStart, goal.WeekEnd, goal.WeekEnd.DayNumber - today.DayNumber, goal.RewardTitle, goal.RewardEmoji,
                goal.Target, total, goal.Repeat, goal.ReachedAt, contributors);
        }

        return new FamilyGoalStateDto(today, dto, lastWeek, suggested);
    }

    public async Task<FamilyGoalStateDto> SetAsync(Guid familyId, FamilyGoalRequest request, Guid userId, CancellationToken ct)
    {
        var tz = await db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.TimeZoneId).FirstAsync(ct);
        var week = FamilyGoal.WeekOf(FamilyTimeZone.LocalDate(clock.GetUtcNow(), tz));
        var goal = await db.FamilyGoals.FirstOrDefaultAsync(g => g.FamilyId == familyId && g.WeekStart == week, ct);
        if (goal is null)
        {
            db.FamilyGoals.Add(new FamilyGoal(familyId, week, request.RewardTitle, request.RewardEmoji, request.Target, request.Repeat, userId, clock.GetUtcNow()));
        }
        else
        {
            goal.Update(request.RewardTitle, request.RewardEmoji, request.Target, request.Repeat);
        }

        await db.SaveChangesAsync(ct);
        return await StateAsync(familyId, ct);
    }

    /// <summary>Ends this week's goal; a repeating goal stops repeating.</summary>
    public async Task EndAsync(Guid familyId, CancellationToken ct)
    {
        var tz = await db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.TimeZoneId).FirstAsync(ct);
        var week = FamilyGoal.WeekOf(FamilyTimeZone.LocalDate(clock.GetUtcNow(), tz));
        await db.FamilyGoals.Where(g => g.FamilyId == familyId && g.WeekStart == week).ExecuteDeleteAsync(ct);
        foreach (var old in await db.FamilyGoals.Where(g => g.FamilyId == familyId && g.Repeat && g.WeekStart < week).ToListAsync(ct))
        {
            old.Update(old.RewardTitle, old.RewardEmoji, old.Target, false);
        }

        await db.SaveChangesAsync(ct);
    }

    /// <summary>Job: announces goals reached since the last run (a child's approved cherry or a parent's task may have
    /// tipped it over while nobody had the app open).</summary>
    public async Task CheckAllAsync(CancellationToken ct)
    {
        var since = DateOnly.FromDateTime(clock.GetUtcNow().UtcDateTime).AddDays(-7);
        var open = await db.FamilyGoals.Where(g => g.ReachedAt == null && g.WeekStart >= since).Select(g => g.FamilyId).Distinct().ToListAsync(ct);
        foreach (var familyId in open)
        {
            try
            {
                await StateAsync(familyId, ct);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogWarning(ex, "Family goal check failed for {FamilyId}", familyId);
            }
        }
    }

    /// <summary>This week's goal; on a new week a repeating goal from last week starts again.</summary>
    private async Task<FamilyGoal?> CurrentAsync(Guid familyId, DateOnly week, CancellationToken ct)
    {
        var goal = await db.FamilyGoals.FirstOrDefaultAsync(g => g.FamilyId == familyId && g.WeekStart == week, ct);
        if (goal is not null)
        {
            return goal;
        }

        var last = await db.FamilyGoals.AsNoTracking().Where(g => g.FamilyId == familyId && g.WeekStart < week).OrderByDescending(g => g.WeekStart).FirstOrDefaultAsync(ct);
        if (last is not { Repeat: true })
        {
            return null;
        }

        goal = new FamilyGoal(familyId, week, last.RewardTitle, last.RewardEmoji, last.Target, true, last.ByUserId, clock.GetUtcNow());
        db.FamilyGoals.Add(goal);
        try
        {
            await db.SaveChangesAsync(ct);
            return goal;
        }
        catch (DbUpdateException)
        {
            // Another request started it at the same moment.
            db.ChangeTracker.Clear();
            return await db.FamilyGoals.FirstOrDefaultAsync(g => g.FamilyId == familyId && g.WeekStart == week, ct);
        }
    }

    /// <summary>Children: every cherry earned this week (spending does not count). Parents: each finished task or school
    /// run adds <see cref="FamilyGoal.AdultTaskCherries"/>. Caregivers are not part of it.</summary>
    private async Task<List<GoalContributorDto>> ContributorsAsync(Guid familyId, DateOnly week, string tz, CancellationToken ct)
    {
        var end = week.AddDays(7);
        var (start, stop) = (FamilyTimeZone.StartOfDay(week, tz), FamilyTimeZone.StartOfDay(end, tz));

        var children = await db.Children.AsNoTracking().Where(c => c.FamilyId == familyId).OrderBy(c => c.CreatedAt)
            .Select(c => new { c.Id, c.FirstName, c.Color }).ToListAsync(ct);
        var cherries = await db.PointEntries.AsNoTracking().Where(p => p.FamilyId == familyId && p.Points > 0 && p.Kind != PointKind.Allowance && p.Day >= week && p.Day < end)
            .GroupBy(p => p.ChildId).Select(g => new { g.Key, Sum = g.Sum(p => p.Points) }).ToDictionaryAsync(g => g.Key, g => g.Sum, ct);

        var parents = await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == familyId && m.Role != FamilyRole.Caregiver).OrderBy(m => m.CreatedAt)
            .Join(db.Users.AsNoTracking(), m => m.UserId, u => u.Id, (m, u) => new { m.UserId, u.DisplayName }).ToListAsync(ct);
        var tasks = await db.Tasks.AsNoTracking()
            .Where(t => t.FamilyId == familyId && t.CompletedByUserId != null && t.CompletedAt >= start && t.CompletedAt < stop)
            .GroupBy(t => t.CompletedByUserId!.Value).Select(g => new { g.Key, Count = g.Count() }).ToDictionaryAsync(g => g.Key, g => g.Count, ct);
        var runs = await db.DutyDones.AsNoTracking()
            .Where(d => d.FamilyId == familyId && d.ByUserId != null && d.Date >= week && d.Date < end)
            .GroupBy(d => d.ByUserId!.Value).Select(g => new { g.Key, Count = g.Count() }).ToDictionaryAsync(g => g.Key, g => g.Count, ct);

        return children.Select(c => new GoalContributorDto("Child", c.Id, c.FirstName, c.Color, cherries.GetValueOrDefault(c.Id)))
            .Concat(parents.Select(p => new GoalContributorDto("Adult", p.UserId, FirstName(p.DisplayName), null,
                (tasks.GetValueOrDefault(p.UserId) + runs.GetValueOrDefault(p.UserId)) * FamilyGoal.AdultTaskCherries)))
            .ToList();
    }

    private static string FirstName(string name) => name.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? name;

    /// <summary>"🎉 Aile görevi tamam!" to every parent. Best effort; the caller saves.</summary>
    private async Task AnnounceAsync(FamilyGoal goal, int total, CancellationToken ct)
    {
        try
        {
            var parents = await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == goal.FamilyId && m.Role != FamilyRole.Caregiver)
                .Join(db.Users.AsNoTracking(), m => m.UserId, u => u.Id, (m, u) => new { u.Id, u.Locale }).ToListAsync(ct);
            foreach (var p in parents)
            {
                var tr = Locales.IsTurkish(p.Locale);
                await publisher.AddAsync(p.Id, goal.FamilyId, NotificationKind.FamilyGoalReached,
                    tr ? "🎉 Aile görevi tamam!" : "🎉 Family goal reached!",
                    tr ? $"{total} kiraz toplandı: {goal.RewardEmoji} {goal.RewardTitle}" : $"{total} cherries together: {goal.RewardEmoji} {goal.RewardTitle}",
                    null, goal.Id, $"goal:{goal.Id:N}:{p.Id:N}", ct);
            }

            await db.SaveChangesAsync(ct);
            await publisher.FlushPushAsync(ct);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Family goal notification failed");
        }
    }
}

/// <summary>Parents set and see this week's goal (caregivers are not part of it).</summary>
[ApiController]
[Authorize(Policy = Policies.FamilyMember)]
[Route("api/v1/families/{familyId:guid}/goal")]
public class FamilyGoalController(FamilyGoalService goals) : ControllerBase
{
    [HttpGet]
    public Task<FamilyGoalStateDto> Get(Guid familyId, CancellationToken ct) => goals.StateAsync(familyId, ct);

    [HttpPut]
    public Task<FamilyGoalStateDto> Set(Guid familyId, FamilyGoalRequest request, CancellationToken ct) => goals.SetAsync(familyId, request, User.UserId(), ct);

    [HttpDelete]
    public async Task<FamilyGoalStateDto> End(Guid familyId, CancellationToken ct)
    {
        await goals.EndAsync(familyId, ct);
        return await goals.StateAsync(familyId, ct);
    }
}

/// <summary>The child's phone shows the same goal in the jar tab.</summary>
[ApiController]
[Authorize(Policy = ChildDeviceAuth.Policy)]
[Route("api/v1/child/goal")]
public class ChildGoalController(FamilyGoalService goals) : ControllerBase
{
    [HttpGet]
    public Task<FamilyGoalStateDto> Get(CancellationToken ct) => goals.StateAsync(User.ChildFamilyId(), ct);
}
