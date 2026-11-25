using Hally.Domain.Common;

namespace Hally.Domain.Goals;

/// <summary>
/// "Haftalık aile görevi": a shared cherry target for one week (Monday to Sunday) and the reward the family earns
/// together. Everyone's cherries count towards it, parents' finished tasks too; nothing is taken from a child's own jar.
/// </summary>
public class FamilyGoal : Entity
{
    public const int MinTarget = 10;
    public const int MaxTarget = 1000;

    /// <summary>What a parent's finished task or school run adds to the goal.</summary>
    public const int AdultTaskCherries = 2;

    private FamilyGoal() { }

    public FamilyGoal(Guid familyId, DateOnly weekStart, string rewardTitle, string rewardEmoji, int target, bool repeat, Guid? byUserId, DateTimeOffset now)
    {
        if (weekStart.DayOfWeek != DayOfWeek.Monday)
        {
            throw new ArgumentException("A goal week starts on Monday.", nameof(weekStart));
        }

        FamilyId = familyId;
        WeekStart = weekStart;
        ByUserId = byUserId;
        CreatedAt = now;
        Update(rewardTitle, rewardEmoji, target, repeat);
    }

    public Guid FamilyId { get; private set; }
    public DateOnly WeekStart { get; private set; }
    public string RewardTitle { get; private set; } = default!;
    public string RewardEmoji { get; private set; } = default!;
    public int Target { get; private set; }

    /// <summary>Start the same goal again every Monday.</summary>
    public bool Repeat { get; private set; }

    public Guid? ByUserId { get; private set; }
    public DateTimeOffset? ReachedAt { get; private set; }

    public DateOnly WeekEnd => WeekStart.AddDays(6);

    public void Update(string rewardTitle, string rewardEmoji, int target, bool repeat)
    {
        if (string.IsNullOrWhiteSpace(rewardTitle) || rewardTitle.Trim().Length > 60)
        {
            throw new DomainException("goal.reward_invalid", "Reward must be 1-60 characters.");
        }

        if (string.IsNullOrWhiteSpace(rewardEmoji) || rewardEmoji.Trim().Length > 8)
        {
            throw new DomainException("goal.emoji_invalid", "Pick one emoji.");
        }

        if (target is < MinTarget or > MaxTarget)
        {
            throw new DomainException("goal.target_invalid", $"Target must be {MinTarget}-{MaxTarget} cherries.");
        }

        RewardTitle = rewardTitle.Trim();
        RewardEmoji = rewardEmoji.Trim();
        if (target > Target && ReachedAt is not null)
        {
            ReachedAt = null;
        }

        Target = target;
        Repeat = repeat;
    }

    /// <returns>true the first time the total reaches the target.</returns>
    public bool CheckReached(int total, DateTimeOffset now)
    {
        if (ReachedAt is not null || total < Target)
        {
            return false;
        }

        ReachedAt = now;
        return true;
    }

    /// <summary>The Monday of the week <paramref name="day"/> is in.</summary>
    public static DateOnly WeekOf(DateOnly day) => day.AddDays(-(((int)day.DayOfWeek + 6) % 7));
}
