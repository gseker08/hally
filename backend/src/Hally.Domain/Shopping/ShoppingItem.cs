using Hally.Domain.Common;

namespace Hally.Domain.Shopping;

/// <summary>One line on the family's shared shopping list. Checked items stay (crossed out) until someone clears them.</summary>
public class ShoppingItem : Entity
{
    public const int MaxTextLength = 80;
    public const int MaxQuantityLength = 20;

    private ShoppingItem() { }

    public ShoppingItem(Guid familyId, Guid addedByUserId, string text, string? quantity, DateTimeOffset now)
    {
        FamilyId = familyId;
        AddedByUserId = addedByUserId;
        CreatedAt = now;
        Edit(text, quantity);
    }

    public Guid FamilyId { get; private set; }
    public string Text { get; private set; } = default!;

    /// <summary>Free text such as "2 kg" or "3 adet".</summary>
    public string? Quantity { get; private set; }

    public Guid? AddedByUserId { get; private set; }
    public DateTimeOffset? CheckedAt { get; private set; }
    public Guid? CheckedByUserId { get; private set; }

    public bool IsChecked => CheckedAt is not null;

    /// <summary>Lower-cased text, so "Süt" and "süt" are the same item.</summary>
    public static string Normalize(string text) => text.Trim().ToLower(System.Globalization.CultureInfo.GetCultureInfo("tr-TR"));

    public void Edit(string text, string? quantity)
    {
        if (string.IsNullOrWhiteSpace(text) || text.Trim().Length > MaxTextLength)
        {
            throw new DomainException("shopping.text_invalid", $"Item must be 1-{MaxTextLength} characters.");
        }

        if (quantity is { } q && q.Trim().Length > MaxQuantityLength)
        {
            throw new DomainException("shopping.quantity_invalid", $"Quantity is at most {MaxQuantityLength} characters.");
        }

        Text = text.Trim();
        Quantity = string.IsNullOrWhiteSpace(quantity) ? null : quantity.Trim();
    }

    public void Check(Guid userId, DateTimeOffset now)
    {
        if (IsChecked)
        {
            return;
        }

        CheckedAt = now;
        CheckedByUserId = userId;
    }

    public void Uncheck()
    {
        CheckedAt = null;
        CheckedByUserId = null;
    }
}
