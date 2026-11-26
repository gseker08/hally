using System.Security.Cryptography;
using System.Text;
using Hally.Domain.Common;

namespace Hally.Domain.Activities;

public enum ActivityPlace
{
    Indoor,
    Outdoor,
}

/// <summary>A screen-free idea from Hally's own list ("Şimdi ne yapsam?").</summary>
/// <param name="Key">Stable name; the id is derived from it.</param>
/// <param name="MinAge">Youngest age it suits (whole years).</param>
/// <param name="MaxAge">Oldest age it suits.</param>
public sealed record CatalogActivity(
    string Key,
    string Emoji,
    ActivityPlace Place,
    int MinAge,
    int MaxAge,
    int Minutes,
    int Cherries)
{
    public Guid Id { get; } = ActivityCatalog.IdOf(Key);

    /// <summary>The title in <paramref name="lang"/>; the texts are in Hally.Domain/Localization.</summary>
    public string Title(string? lang) => Texts.Get(lang, $"activity.{Key}.title");

    public string Hint(string? lang) => Texts.Get(lang, $"activity.{Key}.hint");

    public bool Suits(int? age) => age is not { } a || (a >= MinAge && a <= MaxAge);
}

/// <summary>Hally's built-in screen-free ideas. Ids never change, so claims and cherries keep pointing at the same idea.</summary>
public static class ActivityCatalog
{
    /// <summary>At most this many "Yaptım" for ideas per child per day, so the jar cannot be filled by tapping.</summary>
    public const int DailyLimit = 3;

    public static Guid IdOf(string key) => new(MD5.HashData(Encoding.UTF8.GetBytes($"hally-activity:{key}")));

    public static readonly IReadOnlyList<CatalogActivity> All =
    [
        new("leaf-hunt", "🌳", ActivityPlace.Outdoor, 3, 10, 20, 3),
        new("lego-bridge", "🧱", ActivityPlace.Indoor, 4, 12, 30, 3),
        new("read-15", "📚", ActivityPlace.Indoor, 6, 15, 15, 5),
        new("picture-book", "📖", ActivityPlace.Indoor, 2, 6, 15, 3),
        new("draw-family", "🎨", ActivityPlace.Indoor, 3, 12, 20, 2),
        new("animal-yoga", "🧘", ActivityPlace.Indoor, 3, 10, 10, 2),
        new("dance", "💃", ActivityPlace.Indoor, 3, 14, 10, 2),
        new("puzzle", "🧩", ActivityPlace.Indoor, 3, 14, 30, 3),
        new("tidy-toys", "🧸", ActivityPlace.Indoor, 3, 10, 10, 2),
        new("help-cook", "🥪", ActivityPlace.Indoor, 5, 15, 20, 3),
        new("paper-plane", "✈️", ActivityPlace.Indoor, 5, 14, 15, 2),
        new("play-dough", "🟣", ActivityPlace.Indoor, 3, 9, 20, 2),
        new("board-game", "🎲", ActivityPlace.Indoor, 4, 15, 30, 3),
        new("letter", "✉️", ActivityPlace.Indoor, 6, 14, 20, 3),
        new("instrument", "🎵", ActivityPlace.Indoor, 6, 17, 15, 3),
        new("plant", "🪴", ActivityPlace.Indoor, 3, 12, 10, 2),
        new("fort", "🏰", ActivityPlace.Indoor, 3, 10, 30, 2),
        new("journal", "📝", ActivityPlace.Indoor, 8, 17, 15, 3),
        new("origami", "🦢", ActivityPlace.Indoor, 8, 17, 20, 3),
        new("stretch", "🤸", ActivityPlace.Indoor, 8, 17, 10, 2),
        new("park", "🛝", ActivityPlace.Outdoor, 2, 12, 45, 3),
        new("bike", "🚲", ActivityPlace.Outdoor, 5, 15, 30, 3),
        new("ball", "⚽", ActivityPlace.Outdoor, 4, 15, 30, 3),
        new("chalk", "🖍️", ActivityPlace.Outdoor, 3, 10, 20, 2),
        new("walk", "🚶", ActivityPlace.Outdoor, 3, 17, 30, 3),
        new("jump-rope", "🪢", ActivityPlace.Outdoor, 6, 14, 15, 2),
    ];

    public static CatalogActivity? Find(Guid id) => All.FirstOrDefault(a => a.Id == id);
}

/// <summary>A screen-free idea a parent added for their own family ("Ebeveyn kendi fikirlerini ekleyebilir").</summary>
public class FamilyActivity : Entity
{
    public const int MaxPerFamily = 30;

    private FamilyActivity() { }

    public FamilyActivity(Guid familyId, string title, string emoji, int cherries, ActivityPlace place, Guid byUserId, DateTimeOffset now)
    {
        if (string.IsNullOrWhiteSpace(title) || title.Trim().Length > 60)
        {
            throw new DomainException("activity.title_invalid", "Title must be 1-60 characters.");
        }

        if (string.IsNullOrWhiteSpace(emoji) || emoji.Trim().Length > 8)
        {
            throw new DomainException("activity.emoji_invalid", "Pick one emoji.");
        }

        if (cherries is < 1 or > 10)
        {
            throw new DomainException("activity.cherries_invalid", "Cherries must be 1-10.");
        }

        FamilyId = familyId;
        Title = title.Trim();
        Emoji = emoji.Trim();
        Cherries = cherries;
        Place = place;
        ByUserId = byUserId;
        CreatedAt = now;
    }

    public Guid FamilyId { get; private set; }
    public string Title { get; private set; } = default!;
    public string Emoji { get; private set; } = default!;
    public int Cherries { get; private set; }
    public ActivityPlace Place { get; private set; }
    public Guid? ByUserId { get; private set; }
}
