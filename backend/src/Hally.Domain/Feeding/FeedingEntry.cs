using Hally.Domain.Common;

namespace Hally.Domain.Feeding;

public enum FeedingKind
{
    Breast,
    Bottle,
    Solid,
}

public enum BreastSide
{
    Left,
    Right,
    Both,
}

/// <summary>One feed: breast (side and minutes), bottle (ml) or solid food (what was eaten).</summary>
public class FeedingEntry : Entity
{
    private FeedingEntry() { }

    public FeedingEntry(Guid familyId, Guid childId, Guid userId, FeedingKind kind, DateTimeOffset at, BreastSide? side, int? minutes,
        int? amountMl, string? food, string? note, DateTimeOffset now)
    {
        if (at > now.AddMinutes(5))
        {
            throw new DomainException("feeding.in_future", "A feed cannot be in the future.");
        }

        if (at < now.AddDays(-14))
        {
            throw new DomainException("feeding.too_old", "Feeds can be added for the last 14 days.");
        }

        switch (kind)
        {
            case FeedingKind.Breast when side is null:
                throw new DomainException("feeding.side_required", "Pick the side.");
            case FeedingKind.Bottle when amountMl is null:
                throw new DomainException("feeding.amount_required", "Enter the amount.");
            case FeedingKind.Solid when string.IsNullOrWhiteSpace(food):
                throw new DomainException("feeding.food_required", "Enter what was eaten.");
        }

        if (minutes is < 1 or > 120 || amountMl is < 5 or > 500 || food is { Length: > 80 } || note is { Length: > 200 })
        {
            throw new DomainException("feeding.value_invalid", "Minutes 1-120, amount 5-500 ml, food up to 80 and note up to 200 characters.");
        }

        FamilyId = familyId;
        ChildId = childId;
        ByUserId = userId;
        Kind = kind;
        At = at;
        Side = kind == FeedingKind.Breast ? side : null;
        Minutes = kind == FeedingKind.Breast ? minutes : null;
        AmountMl = kind == FeedingKind.Bottle ? amountMl : null;
        Food = kind == FeedingKind.Solid ? food!.Trim() : null;
        Note = string.IsNullOrWhiteSpace(note) ? null : note.Trim();
        CreatedAt = now;
    }

    public Guid FamilyId { get; private set; }
    public Guid ChildId { get; private set; }
    public Guid? ByUserId { get; private set; }
    public FeedingKind Kind { get; private set; }
    public DateTimeOffset At { get; private set; }
    public BreastSide? Side { get; private set; }
    public int? Minutes { get; private set; }
    public int? AmountMl { get; private set; }
    public string? Food { get; private set; }
    public string? Note { get; private set; }

    /// <summary>The side to offer next: the other one after Left or Right; null after Both or without a breast feed.</summary>
    public static BreastSide? NextSide(BreastSide? last) => last switch
    {
        BreastSide.Left => BreastSide.Right,
        BreastSide.Right => BreastSide.Left,
        _ => null,
    };
}
