using Hally.Domain.Common;

namespace Hally.Domain.Users;

public class User : Entity
{
    private readonly List<ExternalLogin> _logins = [];

    private User() { }

    public User(string email, string displayName, string locale)
    {
        Email = email.Trim().ToLowerInvariant();
        DisplayName = displayName.Trim();
        Locale = Locales.Normalize(locale);
    }

    public string Email { get; private set; } = default!;
    public string DisplayName { get; private set; } = default!;
    public string Locale { get; private set; } = Locales.Turkish;
    public IReadOnlyCollection<ExternalLogin> Logins => _logins;

    /// <summary>Evening prep: a short "tomorrow" summary pushed at <see cref="EveningPrepHour"/> family-local time.</summary>
    public bool EveningPrepEnabled { get; private set; } = true;

    public int EveningPrepHour { get; private set; } = 20;

    public void UpdateNotificationSettings(bool eveningPrepEnabled, int eveningPrepHour)
    {
        if (eveningPrepHour is < 16 or > 22)
        {
            throw new DomainException("user.prep_hour_invalid", "Evening prep hour must be between 16 and 22.");
        }

        EveningPrepEnabled = eveningPrepEnabled;
        EveningPrepHour = eveningPrepHour;
    }

    public void LinkLogin(string provider, string subject)
    {
        if (_logins.Any(l => l.Provider == provider && l.Subject == subject))
        {
            return;
        }

        _logins.Add(new ExternalLogin(Id, provider, subject));
    }

    public void UpdateProfile(string displayName, string locale)
    {
        if (string.IsNullOrWhiteSpace(displayName))
        {
            throw new DomainException("user.display_name_required", "Display name is required.");
        }

        DisplayName = displayName.Trim();
        Locale = Locales.Normalize(locale);
    }
}

public class ExternalLogin : Entity
{
    private ExternalLogin() { }

    public ExternalLogin(Guid userId, string provider, string subject)
    {
        UserId = userId;
        Provider = provider;
        Subject = subject;
    }

    public Guid UserId { get; private set; }
    public string Provider { get; private set; } = default!;
    public string Subject { get; private set; } = default!;
}

public static class Locales
{
    public const string Turkish = "tr";
    public const string English = "en";
    public const string German = "de";

    /// <summary>The languages the app and the server texts speak.</summary>
    public static readonly IReadOnlyList<string> Supported = [Turkish, English, German];

    /// <summary>Two-letter code of a supported language. Missing means Turkish (the launch market); any other
    /// language gets English.</summary>
    public static string Normalize(string? locale)
    {
        var two = (locale ?? string.Empty).Trim().ToLowerInvariant();
        two = two.Length >= 2 ? two[..2] : two;
        if (two.Length == 0)
        {
            return Turkish;
        }

        return Supported.Contains(two) ? two : English;
    }

    public static bool IsTurkish(string? locale) => Normalize(locale) == Turkish;
}
