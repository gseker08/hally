using Hally.Domain.Common;

namespace Hally.Domain.Allowance;

/// <summary>
/// Harçlık for one child: what cherries are worth in money, an optional weekly allowance in cherries, and the child's
/// own savings goal ("Bisiklet · 300 kiraz"). Hally never holds or moves money; it only keeps track of what the
/// parents said they paid.
/// </summary>
public class AllowancePlan : Entity
{
    public const int MaxWeekly = 200;
    public const int MaxGoal = 10_000;

    private AllowancePlan() { }

    public AllowancePlan(Guid familyId, Guid childId, DateTimeOffset now)
    {
        FamilyId = familyId;
        ChildId = childId;
        CreatedAt = now;
    }

    public Guid FamilyId { get; private set; }
    public Guid ChildId { get; private set; }

    /// <summary>"10 kiraz = 5 ₺": this many cherries ...</summary>
    public int RateCherries { get; private set; } = 10;

    /// <summary>... are worth this much money.</summary>
    public decimal RateAmount { get; private set; } = 5m;

    public string Currency { get; private set; } = "TRY";

    /// <summary>Cherries added to the jar every Monday; 0 is off.</summary>
    public int WeeklyCherries { get; private set; }

    /// <summary>The Monday the weekly allowance was last added (family-local), so the job adds it once a week.</summary>
    public DateOnly? WeeklyPaidFor { get; private set; }

    /// <summary>"Ödedim" also writes the money to Harcamalar.</summary>
    public bool AddToExpenses { get; private set; } = true;

    public string? GoalTitle { get; private set; }
    public string? GoalEmoji { get; private set; }
    public int? GoalCherries { get; private set; }

    public void Update(int rateCherries, decimal rateAmount, string currency, int weeklyCherries, bool addToExpenses)
    {
        if (rateCherries is < 1 or > 1000)
        {
            throw new DomainException("allowance.rate_invalid", "Cherries per step must be 1-1000.");
        }

        if (rateAmount <= 0 || rateAmount > 10_000 || decimal.Round(rateAmount, 2) != rateAmount)
        {
            throw new DomainException("allowance.amount_invalid", "The amount must be above 0, at most 10,000, with up to 2 decimals.");
        }

        if (weeklyCherries is < 0 or > MaxWeekly)
        {
            throw new DomainException("allowance.weekly_invalid", $"Weekly allowance must be 0-{MaxWeekly} cherries.");
        }

        currency = string.IsNullOrWhiteSpace(currency) ? "TRY" : currency.Trim().ToUpperInvariant();
        if (currency.Length != 3)
        {
            throw new DomainException("allowance.currency_invalid", "Currency is a 3-letter code.");
        }

        RateCherries = rateCherries;
        RateAmount = rateAmount;
        Currency = currency;
        WeeklyCherries = weeklyCherries;
        AddToExpenses = addToExpenses;
    }

    public void SetGoal(string title, string? emoji, int cherries)
    {
        title = title?.Trim() ?? "";
        if (title.Length is 0 or > 40)
        {
            throw new DomainException("allowance.goal_title_invalid", "The goal needs a name of 1-40 characters.");
        }

        if (cherries is < 10 or > MaxGoal)
        {
            throw new DomainException("allowance.goal_invalid", $"The goal must be 10-{MaxGoal} cherries.");
        }

        GoalTitle = title;
        GoalEmoji = string.IsNullOrWhiteSpace(emoji) ? "🎯" : emoji.Trim()[..Math.Min(emoji.Trim().Length, 8)];
        GoalCherries = cherries;
    }

    public void ClearGoal()
    {
        GoalTitle = null;
        GoalEmoji = null;
        GoalCherries = null;
    }

    /// <summary>The money for <paramref name="cherries"/>; only whole steps convert.</summary>
    public decimal AmountFor(int cherries)
    {
        if (cherries < RateCherries || cherries % RateCherries != 0)
        {
            throw new DomainException("allowance.cherries_invalid", $"Cherries convert in steps of {RateCherries}.");
        }

        return cherries / RateCherries * RateAmount;
    }

    /// <summary>Marks this week's allowance as added; false when it already was.</summary>
    public bool TakeWeek(DateOnly monday)
    {
        if (WeeklyCherries == 0 || WeeklyPaidFor >= monday)
        {
            return false;
        }

        WeeklyPaidFor = monday;
        return true;
    }
}

public enum AllowanceStatus
{
    Pending,
    Paid,
    Declined,
}

/// <summary>"Harçlığa çevir": the child asks to turn cherries into pocket money. A parent pays outside Hally and taps
/// "Ödedim"; only then do the cherries leave the jar.</summary>
public class AllowanceRequest : Entity
{
    private AllowanceRequest() { }

    public AllowanceRequest(Guid familyId, Guid childId, int cherries, decimal amount, string currency, DateTimeOffset now)
    {
        FamilyId = familyId;
        ChildId = childId;
        Cherries = cherries;
        Amount = amount;
        Currency = currency;
        CreatedAt = now;
    }

    public Guid FamilyId { get; private set; }
    public Guid ChildId { get; private set; }
    public int Cherries { get; private set; }
    public decimal Amount { get; private set; }
    public string Currency { get; private set; } = "TRY";
    public AllowanceStatus Status { get; private set; }
    public Guid? DecidedByUserId { get; private set; }
    public DateTimeOffset? DecidedAt { get; private set; }
    public Guid? ExpenseId { get; private set; }

    public void Decide(bool paid, Guid userId, Guid? expenseId, DateTimeOffset now)
    {
        if (Status != AllowanceStatus.Pending)
        {
            throw new DomainException("allowance.already_decided", "This request was already answered.");
        }

        Status = paid ? AllowanceStatus.Paid : AllowanceStatus.Declined;
        DecidedByUserId = userId;
        DecidedAt = now;
        ExpenseId = expenseId;
    }
}
