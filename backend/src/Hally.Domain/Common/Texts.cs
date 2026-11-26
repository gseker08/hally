using System.Collections.Concurrent;
using System.Globalization;
using System.Text.Json;
using Hally.Domain.Users;

namespace Hally.Domain.Common;

/// <summary>
/// Server texts (pushes, the morning summary, calendar titles, built-in ideas) in every app language. Each language is
/// one flat JSON file in <c>Hally.Domain/Localization</c> (<c>"push.bedtime.title": "🌙 {name} yatağında"</c>),
/// embedded in the assembly. A key missing in a language falls back to English. Placeholders are <c>{name}</c>;
/// counts pick <c>key.one</c> or <c>key.other</c>.
/// </summary>
public static class Texts
{
    private static readonly ConcurrentDictionary<string, IReadOnlyDictionary<string, string>> Cache = new();

    /// <summary>The text for <paramref name="key"/> in <paramref name="locale"/>, with <c>{placeholders}</c> filled in.</summary>
    public static string Get(string? locale, string key, params (string Name, object? Value)[] args)
    {
        var lang = Locales.Normalize(locale);
        var text = Find(lang, key) ?? throw new KeyNotFoundException($"No server text '{key}'.");
        return Fill(text, lang, args);
    }

    /// <summary><c>key.one</c> when <paramref name="count"/> is 1, else <c>key.other</c>; <c>{count}</c> is filled in too.</summary>
    public static string Plural(string? locale, string key, int count, params (string Name, object? Value)[] args) =>
        Get(locale, count == 1 ? $"{key}.one" : $"{key}.other", [.. args, ("count", count)]);

    /// <summary>Like <see cref="Get"/>, or null when no language (not even English) has the key.</summary>
    public static string? TryGet(string? locale, string key)
    {
        var lang = Locales.Normalize(locale);
        return Find(lang, key);
    }

    /// <summary>The culture for dates and numbers in <paramref name="locale"/>.</summary>
    public static CultureInfo Culture(string? locale) => Locales.Normalize(locale) switch
    {
        Locales.Turkish => CultureInfo.GetCultureInfo("tr-TR"),
        Locales.English => CultureInfo.GetCultureInfo("en-US"),
        var l => CultureInfo.GetCultureInfo(l),
    };

    /// <summary>All keys of one language, for tests.</summary>
    public static IReadOnlyDictionary<string, string> All(string lang) => Load(lang);

    private static string? Find(string lang, string key) =>
        Load(lang).TryGetValue(key, out var text) ? text
        : Load(Locales.English).TryGetValue(key, out var english) ? english
        : null;

    private static string Fill(string text, string lang, (string Name, object? Value)[] args)
    {
        if (args.Length == 0)
        {
            return text;
        }

        var culture = Culture(lang);
        foreach (var (name, value) in args)
        {
            text = text.Replace("{" + name + "}", Convert.ToString(value, culture));
        }

        return text;
    }

    private static IReadOnlyDictionary<string, string> Load(string lang) => Cache.GetOrAdd(lang, l =>
    {
        var assembly = typeof(Texts).Assembly;
        using var stream = assembly.GetManifestResourceStream($"Hally.Domain.Localization.{l}.json");
        if (stream is null)
        {
            return new Dictionary<string, string>();
        }

        return JsonSerializer.Deserialize<Dictionary<string, string>>(stream) ?? [];
    });
}
