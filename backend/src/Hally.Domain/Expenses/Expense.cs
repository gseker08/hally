using Hally.Domain.Common;

namespace Hally.Domain.Expenses;

public enum ExpenseCategory
{
    School,
    Health,
    Clothes,
    Activity,
    Food,
    Other,
}

/// <summary>
/// A child-related cost one adult paid. It is split equally among <see cref="SharedWith"/>, the family's adults when it
/// was added, so someone joining later does not change old shares.
/// </summary>
public class Expense : Entity
{
    public const decimal MaxAmount = 1_000_000m;

    private Expense() { }

    public Expense(Guid familyId, string title, decimal amount, ExpenseCategory category, DateOnly date, Guid paidByUserId,
        IReadOnlyList<Guid> sharedWith, Guid? childId, string? note, Guid createdByUserId, DateTimeOffset now)
    {
        if (string.IsNullOrWhiteSpace(title) || title.Trim().Length > 80)
        {
            throw new DomainException("expense.title_invalid", "Title must be 1-80 characters.");
        }

        if (amount <= 0 || amount > MaxAmount || decimal.Round(amount, 2) != amount)
        {
            throw new DomainException("expense.amount_invalid", "Amount must be above 0, at most 1,000,000, with up to 2 decimals.");
        }

        if (sharedWith.Count == 0 || !sharedWith.Contains(paidByUserId))
        {
            throw new DomainException("expense.share_invalid", "The payer must be one of the adults sharing it.");
        }

        if (note is { Length: > 200 })
        {
            throw new DomainException("expense.note_too_long", "Note can be up to 200 characters.");
        }

        FamilyId = familyId;
        Title = title.Trim();
        Amount = amount;
        Category = category;
        Date = date;
        PaidByUserId = paidByUserId;
        SharedWith = sharedWith.Distinct().ToList();
        ChildId = childId;
        Note = string.IsNullOrWhiteSpace(note) ? null : note.Trim();
        CreatedByUserId = createdByUserId;
        CreatedAt = now;
    }

    public Guid FamilyId { get; private set; }
    public string Title { get; private set; } = default!;
    public decimal Amount { get; private set; }
    public ExpenseCategory Category { get; private set; }
    public DateOnly Date { get; private set; }
    public Guid PaidByUserId { get; private set; }
    public List<Guid> SharedWith { get; private set; } = [];
    public Guid? ChildId { get; private set; }
    public string? Note { get; private set; }
    public Guid? CreatedByUserId { get; private set; }

    /// <summary>Each sharer's part; rounding leftovers (a kuruş or two) stay with the payer.</summary>
    public decimal ShareOf(Guid userId)
    {
        if (!SharedWith.Contains(userId))
        {
            return 0;
        }

        var each = decimal.Floor(Amount * 100 / SharedWith.Count) / 100;
        return userId == PaidByUserId ? Amount - each * (SharedWith.Count - 1) : each;
    }
}

/// <summary>Money one adult gave another to even out ("Mehmet paid Ayşe 350 TL").</summary>
public class Settlement : Entity
{
    private Settlement() { }

    public Settlement(Guid familyId, Guid fromUserId, Guid toUserId, decimal amount, DateOnly date, DateTimeOffset now)
    {
        if (fromUserId == toUserId)
        {
            throw new DomainException("settlement.same_person", "Pick the other adult.");
        }

        if (amount <= 0 || amount > Expense.MaxAmount || decimal.Round(amount, 2) != amount)
        {
            throw new DomainException("expense.amount_invalid", "Amount must be above 0, at most 1,000,000, with up to 2 decimals.");
        }

        FamilyId = familyId;
        FromUserId = fromUserId;
        ToUserId = toUserId;
        Amount = amount;
        Date = date;
        CreatedAt = now;
    }

    public Guid FamilyId { get; private set; }
    public Guid FromUserId { get; private set; }
    public Guid ToUserId { get; private set; }
    public decimal Amount { get; private set; }
    public DateOnly Date { get; private set; }

    /// <summary>
    /// Net per adult (positive: the others owe them) from all expenses and settlements.
    /// </summary>
    public static Dictionary<Guid, decimal> Balances(IEnumerable<Expense> expenses, IEnumerable<Settlement> settlements)
    {
        var net = new Dictionary<Guid, decimal>();
        void Add(Guid u, decimal v) => net[u] = net.GetValueOrDefault(u) + v;
        foreach (var e in expenses)
        {
            Add(e.PaidByUserId, e.Amount);
            foreach (var u in e.SharedWith)
            {
                Add(u, -e.ShareOf(u));
            }
        }

        foreach (var s in settlements)
        {
            Add(s.FromUserId, s.Amount);
            Add(s.ToUserId, -s.Amount);
        }

        return net;
    }
}
