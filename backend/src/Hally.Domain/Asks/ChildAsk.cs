using System.Text.Json;
using Hally.Domain.ChildMode;
using Hally.Domain.Common;

namespace Hally.Domain.Asks;

public enum AskStatus
{
    Pending,
    Yes,
    No,
}

/// <summary>
/// A ready-made request on the child's "Bir şey iste" page ("Arkadaşıma gidebilir miyim?", "15 dk daha oyun").
/// Parents edit the list; a family without its own list gets <see cref="Defaults"/> on first use.
/// </summary>
public class AskPreset : Entity
{
    public const int MaxPerFamily = 8;
    public const int MaxOptions = 6;

    private AskPreset() { }

    public AskPreset(Guid familyId, int order, string emoji, string title, string? question, IReadOnlyList<string> options, int? screenMinutes, DateTimeOffset now)
    {
        FamilyId = familyId;
        CreatedAt = now;
        Update(order, emoji, title, question, options, screenMinutes);
    }

    public Guid FamilyId { get; private set; }
    public int Order { get; private set; }
    public string Emoji { get; private set; } = "💬";
    public string Title { get; private set; } = default!;

    /// <summary>A follow-up question with quick answers, e.g. "Kimin evine?" → Zeynep, Can.</summary>
    public string? Question { get; private set; }

    public string OptionsJson { get; private set; } = "[]";

    /// <summary>A "yes" gives this many extra screen minutes today, which really postpones the lock.</summary>
    public int? ScreenMinutes { get; private set; }

    public IReadOnlyList<string> Options => JsonSerializer.Deserialize<List<string>>(OptionsJson) ?? [];

    public void Update(int order, string emoji, string title, string? question, IReadOnlyList<string> options, int? screenMinutes)
    {
        title = title?.Trim() ?? "";
        if (title.Length is 0 or > 40)
        {
            throw new DomainException("ask.title_invalid", "A request needs a title of 1-40 characters.");
        }

        question = string.IsNullOrWhiteSpace(question) ? null : question.Trim();
        if (question is { Length: > 40 })
        {
            throw new DomainException("ask.question_invalid", "The follow-up question is at most 40 characters.");
        }

        var clean = (options ?? []).Select(o => o?.Trim() ?? "").Where(o => o.Length > 0).Distinct().ToList();
        if (clean.Count > MaxOptions || clean.Any(o => o.Length > 20))
        {
            throw new DomainException("ask.options_invalid", $"At most {MaxOptions} quick answers of up to 20 characters.");
        }

        if (screenMinutes is { } m && (m < 5 || m > ScreenBonus.MaxMinutes))
        {
            throw new DomainException("ask.minutes_invalid", $"Extra time must be 5-{ScreenBonus.MaxMinutes} minutes.");
        }

        emoji = string.IsNullOrWhiteSpace(emoji) ? "💬" : emoji.Trim();
        if (emoji.Length > 8)
        {
            throw new DomainException("ask.emoji_invalid", "Emoji is too long.");
        }

        Order = order;
        Emoji = emoji;
        Title = title;
        Question = question;
        OptionsJson = JsonSerializer.Serialize(clean);
        ScreenMinutes = screenMinutes;
    }

    /// <summary>The starting list, in the language of whoever opens it first.</summary>
    /// <summary>The starting list, in <paramref name="lang"/> (Turkish when missing).</summary>
    public static IReadOnlyList<(string Emoji, string Title, string? Question, string[] Options, int? Minutes)> Defaults(string? lang) =>
    [
        ("🏠", Texts.Get(lang, "askPreset.friend"), Texts.Get(lang, "askPreset.friend.question"), [], null),
        ("🎮", Texts.Get(lang, "askPreset.games"), null, [], 15),
        ("🍪", Texts.Get(lang, "askPreset.snack"), null, [], null),
        ("📺", Texts.Get(lang, "askPreset.cartoons"), null, [], null),
    ];
}

/// <summary>
/// "Bir şey iste": a child asks the parents for something from their own phone. Every parent gets a notification
/// with Evet/Hayır; the first answer counts and the child sees it (with an optional note) right away.
/// </summary>
public class ChildAsk : Entity
{
    /// <summary>Open requests one child can have at a time.</summary>
    public const int MaxPending = 3;

    public const int MaxPerDay = 20;
    public const int RetentionDays = 90;

    private ChildAsk() { }

    public ChildAsk(Guid familyId, Guid childId, Guid? presetId, string emoji, string title, string? detail, int? screenMinutes, DateOnly day, DateTimeOffset now)
    {
        title = title?.Trim() ?? "";
        if (title.Length is 0 or > 60)
        {
            throw new DomainException("ask.title_invalid", "A request needs a text of 1-60 characters.");
        }

        detail = string.IsNullOrWhiteSpace(detail) ? null : detail.Trim();
        if (detail is { Length: > 40 })
        {
            throw new DomainException("ask.detail_invalid", "The answer is at most 40 characters.");
        }

        FamilyId = familyId;
        ChildId = childId;
        PresetId = presetId;
        Emoji = string.IsNullOrWhiteSpace(emoji) ? "💬" : emoji;
        Title = title;
        Detail = detail;
        ScreenMinutes = screenMinutes;
        Day = day;
        CreatedAt = now;
    }

    public Guid FamilyId { get; private set; }
    public Guid ChildId { get; private set; }
    public Guid? PresetId { get; private set; }
    public string Emoji { get; private set; } = "💬";
    public string Title { get; private set; } = default!;
    public string? Detail { get; private set; }
    public int? ScreenMinutes { get; private set; }

    /// <summary>The family-local day it was asked; an unanswered request ends with that day.</summary>
    public DateOnly Day { get; private set; }

    public AskStatus Status { get; private set; }
    public Guid? AnsweredByUserId { get; private set; }
    public DateTimeOffset? AnsweredAt { get; private set; }
    public string? Note { get; private set; }

    public static string? CleanNote(string? note)
    {
        note = string.IsNullOrWhiteSpace(note) ? null : note.Trim();
        return note is { Length: > 140 } ? throw new DomainException("ask.note_invalid", "The note is at most 140 characters.") : note;
    }
}
