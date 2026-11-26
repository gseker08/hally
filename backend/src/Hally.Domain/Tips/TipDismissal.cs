using Hally.Domain.Common;

namespace Hally.Domain.Tips;

/// <summary>
/// "Akıllı ipuçları": one member hid one tip. <see cref="Until"/> null is "✕" (never again for this key), a date is
/// "Sonra" (back on that family-local day). Tips themselves are not stored; they are worked out from the family's data
/// on every read, so a key names the situation (kind + child + week/exam), not a row.
/// </summary>
public class TipDismissal : Entity
{
    public const int MaxKey = 160;

    private TipDismissal() { }

    public TipDismissal(Guid familyId, Guid userId, string key, DateOnly? until, DateTimeOffset now)
    {
        if (string.IsNullOrWhiteSpace(key) || key.Length > MaxKey)
        {
            throw new DomainException("tip.key_invalid", "Unknown tip.");
        }

        FamilyId = familyId;
        UserId = userId;
        Key = key;
        CreatedAt = now;
        Set(until, now);
    }

    public Guid FamilyId { get; private set; }
    public Guid UserId { get; private set; }
    public string Key { get; private set; } = default!;

    /// <summary>Null hides the tip for good; otherwise it shows again from this family-local day.</summary>
    public DateOnly? Until { get; private set; }

    public DateTimeOffset UpdatedAt { get; private set; }

    public bool Forever => Until is null;

    public bool Hides(DateOnly today) => Until is not { } until || today < until;

    public void Set(DateOnly? until, DateTimeOffset now)
    {
        Until = until;
        UpdatedAt = now;
    }
}
