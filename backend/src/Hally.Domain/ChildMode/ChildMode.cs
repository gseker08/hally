using Hally.Domain.Common;

namespace Hally.Domain.ChildMode;

/// <summary>A child's own phone, paired with a one-time code from a parent's phone. There is no account, email or
/// password: the device holds a random token (only its hash is stored) that a parent can revoke at any time.</summary>
public class ChildDevice : Entity
{
    private ChildDevice() { }

    public ChildDevice(Guid familyId, Guid childId, string tokenHash, string? name, DateTimeOffset now)
    {
        FamilyId = familyId;
        ChildId = childId;
        TokenHash = tokenHash;
        Name = string.IsNullOrWhiteSpace(name) ? null : name.Trim()[..Math.Min(name.Trim().Length, 60)];
        CreatedAt = now;
        LastSeenAt = now;
    }

    public Guid FamilyId { get; private set; }
    public Guid ChildId { get; private set; }
    public string TokenHash { get; private set; } = default!;
    public string? Name { get; private set; }
    public DateTimeOffset LastSeenAt { get; private set; }
    public DateTimeOffset? RevokedAt { get; private set; }

    public bool IsActive => RevokedAt is null;

    public void Seen(DateTimeOffset now) => LastSeenAt = now;

    public void Revoke(DateTimeOffset now) => RevokedAt ??= now;

    /// <summary>Wrong exit PINs in a row before the phone has to wait.</summary>
    public const int MaxExitTries = 5;

    public static readonly TimeSpan ExitWait = TimeSpan.FromMinutes(15);

    public int ExitFailures { get; private set; }
    public DateTimeOffset? ExitBlockedUntil { get; private set; }

    public bool ExitBlocked(DateTimeOffset now) => ExitBlockedUntil > now;

    /// <summary>Counts a wrong PIN; the fifth in a row blocks tries for <see cref="ExitWait"/>. Returns the tries left.</summary>
    public int ExitFailed(DateTimeOffset now)
    {
        if (ExitBlockedUntil is { } until && until <= now)
        {
            ExitFailures = 0;
            ExitBlockedUntil = null;
        }

        ExitFailures++;
        if (ExitFailures < MaxExitTries)
        {
            return MaxExitTries - ExitFailures;
        }

        ExitBlockedUntil = now + ExitWait;
        return 0;
    }
}

/// <summary>A short-lived six-digit code a parent shows to pair a child's phone. Only the hash is kept; it works once.</summary>
public class PairingCode : Entity
{
    public static readonly TimeSpan Lifetime = TimeSpan.FromMinutes(10);

    private PairingCode() { }

    public PairingCode(Guid familyId, Guid childId, Guid createdByUserId, string codeHash, DateTimeOffset now)
    {
        FamilyId = familyId;
        ChildId = childId;
        CreatedByUserId = createdByUserId;
        CodeHash = codeHash;
        CreatedAt = now;
        ExpiresAt = now + Lifetime;
    }

    public Guid FamilyId { get; private set; }
    public Guid ChildId { get; private set; }
    public Guid CreatedByUserId { get; private set; }
    public string CodeHash { get; private set; } = default!;
    public DateTimeOffset ExpiresAt { get; private set; }
    public DateTimeOffset? UsedAt { get; private set; }

    public bool IsUsable(DateTimeOffset now) => UsedAt is null && ExpiresAt > now;

    public void Use(DateTimeOffset now) => UsedAt = now;
}

public enum ClaimKind
{
    Chore,
    Habit,

    /// <summary>A screen-free idea from "Şimdi ne yapsam?" (built-in or the family's own).</summary>
    Activity,
}

public enum ClaimStatus
{
    Pending,
    Approved,
    Rejected,
}

/// <summary>"Yaptım!": a child marked a chore or habit done on their own phone. With approval on, a parent confirms it
/// and only then the cherries land in the jar.</summary>
public class ChildClaim : Entity
{
    private ChildClaim() { }

    public ChildClaim(Guid familyId, Guid childId, ClaimKind kind, Guid itemId, string title, int points, DateOnly day, DateTimeOffset now)
    {
        FamilyId = familyId;
        ChildId = childId;
        Kind = kind;
        ItemId = itemId;
        Title = title;
        Points = points;
        Day = day;
        CreatedAt = now;
    }

    public Guid FamilyId { get; private set; }
    public Guid ChildId { get; private set; }
    public ClaimKind Kind { get; private set; }

    /// <summary>The chore, habit or screen-free idea.</summary>
    public Guid ItemId { get; private set; }

    public string Title { get; private set; } = default!;
    public int Points { get; private set; }
    public DateOnly Day { get; private set; }
    public ClaimStatus Status { get; private set; }
    public DateTimeOffset? DecidedAt { get; private set; }
    public Guid? DecidedByUserId { get; private set; }

    public void Decide(bool approve, Guid? byUserId, DateTimeOffset now)
    {
        if (Status != ClaimStatus.Pending)
        {
            throw new DomainException("claim.decided", "This was already answered.");
        }

        Status = approve ? ClaimStatus.Approved : ClaimStatus.Rejected;
        DecidedAt = now;
        DecidedByUserId = byUserId;
    }
}

/// <summary>Screen time the child's own phone measured for one family-local day (seconds). The phone reports its running
/// total; the stored value only grows, so a late or repeated report never lowers it.</summary>
public class ScreenUsage : Entity
{
    private ScreenUsage() { }

    public ScreenUsage(Guid familyId, Guid childId, DateOnly day, DateTimeOffset now)
    {
        FamilyId = familyId;
        ChildId = childId;
        Day = day;
        CreatedAt = now;
        UpdatedAt = now;
    }

    public Guid FamilyId { get; private set; }
    public Guid ChildId { get; private set; }
    public DateOnly Day { get; private set; }
    public int Seconds { get; private set; }
    public DateTimeOffset UpdatedAt { get; private set; }

    public void Report(int seconds, DateTimeOffset now)
    {
        Seconds = Math.Max(Seconds, Math.Clamp(seconds, 0, 24 * 3600));
        UpdatedAt = now;
    }
}

public enum BonusSource
{
    Parent,
    Reward,
}

/// <summary>Extra screen minutes for one day: given by a parent or bought with cherries.</summary>
public class ScreenBonus : Entity
{
    public const int MaxMinutes = 240;

    private ScreenBonus() { }

    public ScreenBonus(Guid familyId, Guid childId, DateOnly day, int minutes, BonusSource source, Guid? byUserId, DateTimeOffset now)
    {
        if (minutes is < 1 or > MaxMinutes)
        {
            throw new DomainException("screen_bonus.minutes_invalid", $"Extra time must be 1-{MaxMinutes} minutes.");
        }

        FamilyId = familyId;
        ChildId = childId;
        Day = day;
        Minutes = minutes;
        Source = source;
        ByUserId = byUserId;
        CreatedAt = now;
    }

    public Guid FamilyId { get; private set; }
    public Guid ChildId { get; private set; }
    public DateOnly Day { get; private set; }
    public int Minutes { get; private set; }
    public BonusSource Source { get; private set; }
    public Guid? ByUserId { get; private set; }
}

/// <summary>The cherry streak: days in a row (up to today) with at least one done chore or habit.</summary>
public static class CherryStreak
{
    public const int BonusEvery = 7;
    public const int BonusCherries = 5;

    public static int Length(IReadOnlySet<DateOnly> activeDays, DateOnly today)
    {
        // Today without anything yet doesn't break a streak that ran until yesterday.
        var day = activeDays.Contains(today) ? today : today.AddDays(-1);
        var n = 0;
        while (activeDays.Contains(day))
        {
            n++;
            day = day.AddDays(-1);
        }

        return n;
    }
}
