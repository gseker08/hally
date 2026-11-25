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
    string TitleTr,
    string TitleEn,
    string HintTr,
    string HintEn,
    ActivityPlace Place,
    int MinAge,
    int MaxAge,
    int Minutes,
    int Cherries)
{
    public Guid Id { get; } = ActivityCatalog.IdOf(Key);

    public string Title(bool turkish) => turkish ? TitleTr : TitleEn;

    public string Hint(bool turkish) => turkish ? HintTr : HintEn;

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
        new("leaf-hunt", "🌳", "Bahçede yaprak avı", "Leaf hunt outside", "5 farklı yaprak bul", "Find 5 different leaves", ActivityPlace.Outdoor, 3, 10, 20, 3),
        new("lego-bridge", "🧱", "Legodan köprü yap", "Build a Lego bridge", "Fotoğrafını ailene göster", "Show your family a photo", ActivityPlace.Indoor, 4, 12, 30, 3),
        new("read-15", "📚", "15 dk kitap oku", "Read a book for 15 minutes", "Sevdiğin bir kitap seç", "Pick a book you like", ActivityPlace.Indoor, 6, 15, 15, 5),
        new("picture-book", "📖", "Resimli kitaba bak", "Look at a picture book", "Gördüklerini anlat", "Tell what you see", ActivityPlace.Indoor, 2, 6, 15, 3),
        new("draw-family", "🎨", "Ailene bir resim çiz", "Draw a picture for your family", "Kâğıt ve boya", "Paper and crayons", ActivityPlace.Indoor, 3, 12, 20, 2),
        new("animal-yoga", "🧘", "Hayvan yogası", "Animal yoga", "5 hareket: kedi, köpek, kurbağa…", "5 poses: cat, dog, frog…", ActivityPlace.Indoor, 3, 10, 10, 2),
        new("dance", "💃", "3 şarkıda dans et", "Dance to 3 songs", "Müziği ailen açsın", "Ask a parent to play music", ActivityPlace.Indoor, 3, 14, 10, 2),
        new("puzzle", "🧩", "Yapboz tamamla", "Finish a puzzle", "Yaşına uygun bir yapboz", "One that fits your age", ActivityPlace.Indoor, 3, 14, 30, 3),
        new("tidy-toys", "🧸", "Oyuncaklarını yerleştir", "Put your toys away", "Her şey kendi kutusuna", "Everything back in its box", ActivityPlace.Indoor, 3, 10, 10, 2),
        new("help-cook", "🥪", "Mutfakta yardım et", "Help in the kitchen", "Salata ya da sandviç hazırla", "Make a salad or a sandwich", ActivityPlace.Indoor, 5, 15, 20, 3),
        new("paper-plane", "✈️", "Kâğıttan uçak yap", "Make a paper plane", "En uzağa hangisi uçacak?", "Which one flies the farthest?", ActivityPlace.Indoor, 5, 14, 15, 2),
        new("play-dough", "🟣", "Oyun hamuruyla hayvan yap", "Make an animal from play dough", "Sonra adını koy", "Then give it a name", ActivityPlace.Indoor, 3, 9, 20, 2),
        new("board-game", "🎲", "Ailenle kutu oyunu", "A board game with your family", "Birini davet et", "Invite someone to play", ActivityPlace.Indoor, 4, 15, 30, 3),
        new("letter", "✉️", "Büyükannene mektup yaz", "Write a letter to grandma", "Resimle de süsle", "Decorate it with a drawing", ActivityPlace.Indoor, 6, 14, 20, 3),
        new("instrument", "🎵", "Enstrüman çal", "Play an instrument", "10 dakika pratik", "Practise for 10 minutes", ActivityPlace.Indoor, 6, 17, 15, 3),
        new("plant", "🪴", "Çiçekleri sula", "Water the plants", "Hangisi susamış bak", "Check which one is thirsty", ActivityPlace.Indoor, 3, 12, 10, 2),
        new("fort", "🏰", "Yastıklardan kale kur", "Build a pillow fort", "Sonra birlikte toplayın", "Tidy it up together after", ActivityPlace.Indoor, 3, 10, 30, 2),
        new("journal", "📝", "Günlüğüne yaz", "Write in your journal", "Bugün ne güzeldi?", "What was nice today?", ActivityPlace.Indoor, 8, 17, 15, 3),
        new("origami", "🦢", "Origami yap", "Try origami", "Bir kuş ya da tekne", "A bird or a boat", ActivityPlace.Indoor, 8, 17, 20, 3),
        new("stretch", "🤸", "10 dk egzersiz", "10 minutes of exercise", "Zıpla, esne, mekik çek", "Jump, stretch, sit-ups", ActivityPlace.Indoor, 8, 17, 10, 2),
        new("park", "🛝", "Parka git", "Go to the park", "Bir büyüğünle", "With a grown-up", ActivityPlace.Outdoor, 2, 12, 45, 3),
        new("bike", "🚲", "Bisiklete bin", "Ride your bike", "Kaskını unutma", "Wear your helmet", ActivityPlace.Outdoor, 5, 15, 30, 3),
        new("ball", "⚽", "Top oyna", "Play ball", "Pas, şut ya da basket", "Pass, shoot or shoot hoops", ActivityPlace.Outdoor, 4, 15, 30, 3),
        new("chalk", "🖍️", "Tebeşirle yere çiz", "Chalk drawing outside", "Seksek de çizebilirsin", "Draw a hopscotch too", ActivityPlace.Outdoor, 3, 10, 20, 2),
        new("walk", "🚶", "Ailenle yürüyüş", "A walk with your family", "Yolda 3 kuş say", "Count 3 birds on the way", ActivityPlace.Outdoor, 3, 17, 30, 3),
        new("jump-rope", "🪢", "İp atla", "Jump rope", "Kaç kere atlayabilirsin?", "How many jumps in a row?", ActivityPlace.Outdoor, 6, 14, 15, 2),
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
