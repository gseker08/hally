using Hally.Domain.Common;

namespace Hally.Domain.Points;

/// <summary>A job a child can do for stars ("Odanı topla", 5). <see cref="ChildId"/> null means any child.</summary>
public class Chore : Entity
{
    private Chore() { }

    public Chore(Guid familyId, string title, int points, Guid? childId, DateTimeOffset now)
    {
        FamilyId = familyId;
        Update(title, points, childId);
        CreatedAt = now;
    }

    public Guid FamilyId { get; private set; }
    public string Title { get; private set; } = default!;
    public int Points { get; private set; }
    public Guid? ChildId { get; private set; }

    public void Update(string title, int points, Guid? childId)
    {
        Title = PointRules.CheckTitle(title);
        Points = PointRules.CheckPoints(points);
        ChildId = childId;
    }
}

/// <summary>Something stars can buy ("20 TL harçlık", 50; "Parka gitmek", 20).</summary>
public class Reward : Entity
{
    private Reward() { }

    public Reward(Guid familyId, string title, int cost, DateTimeOffset now)
    {
        FamilyId = familyId;
        Title = PointRules.CheckTitle(title);
        Cost = cost is >= 1 and <= 1000 ? cost : throw new DomainException("points.cost_invalid", "Cost must be 1-1000 stars.");
        CreatedAt = now;
    }

    public Guid FamilyId { get; private set; }
    public string Title { get; private set; } = default!;
    public int Cost { get; private set; }
}

public enum PointKind
{
    Chore,
    Reward,
}

/// <summary>
/// One line of a child's star ledger: plus for a done chore, minus for a reward. The balance is the sum. Titles are
/// copied so the history reads the same after a chore or reward is deleted.
/// </summary>
public class PointEntry : Entity
{
    private PointEntry() { }

    public static PointEntry ForChore(Chore chore, Guid childId, Guid userId, DateOnly day, DateTimeOffset now)
    {
        if (chore.ChildId is { } only && only != childId)
        {
            throw new DomainException("points.chore_other_child", "This chore belongs to another child.");
        }

        return new PointEntry
        {
            FamilyId = chore.FamilyId,
            ChildId = childId,
            Kind = PointKind.Chore,
            ChoreId = chore.Id,
            Title = chore.Title,
            Points = chore.Points,
            Day = day,
            ByUserId = userId,
            CreatedAt = now,
        };
    }

    public static PointEntry ForReward(Reward reward, Guid childId, int balance, Guid userId, DateOnly day, DateTimeOffset now)
    {
        if (balance < reward.Cost)
        {
            throw new DomainException("points.not_enough", $"Needs {reward.Cost} stars; there are {balance}.");
        }

        return new PointEntry
        {
            FamilyId = reward.FamilyId,
            ChildId = childId,
            Kind = PointKind.Reward,
            RewardId = reward.Id,
            Title = reward.Title,
            Points = -reward.Cost,
            Day = day,
            ByUserId = userId,
            CreatedAt = now,
        };
    }

    public Guid FamilyId { get; private set; }
    public Guid ChildId { get; private set; }
    public PointKind Kind { get; private set; }
    public Guid? ChoreId { get; private set; }
    public Guid? RewardId { get; private set; }
    public string Title { get; private set; } = default!;

    /// <summary>Positive for chores, negative for rewards.</summary>
    public int Points { get; private set; }

    /// <summary>Family-local day; a chore counts once per child per day.</summary>
    public DateOnly Day { get; private set; }

    public Guid? ByUserId { get; private set; }
}

public static class PointRules
{
    public static string CheckTitle(string title) =>
        string.IsNullOrWhiteSpace(title) || title.Trim().Length > 60
            ? throw new DomainException("points.title_invalid", "Title must be 1-60 characters.")
            : title.Trim();

    public static int CheckPoints(int points) =>
        points is >= 1 and <= 50 ? points : throw new DomainException("points.points_invalid", "A chore is worth 1-50 stars.");
}
