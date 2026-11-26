using Hally.Domain.Common;

namespace Hally.Domain.Planning;

/// <summary>Where a phone calendar comes from, as far as the app can tell from its account.</summary>
public enum ExternalProvider
{
    Other,
    Google,
    ICloud,
    Outlook,
}

/// <summary>
/// A read-only copy of an event from a parent's phone calendar (Google, iCloud, Outlook…) that the parent chose to share
/// with the family. The phone is the source of truth: the app replaces the parent's whole set on every sync, so an event
/// deleted or moved there is deleted or moved here. Calendars the parent keeps to themselves never reach the server.
/// </summary>
public class ExternalEvent : Entity
{
    public const int MaxSourceKey = 200;
    public const int MaxCalendarName = 100;
    public const int MaxTitle = 200;

    private ExternalEvent() { }

    public ExternalEvent(Guid familyId, Guid ownerUserId, string sourceKey, ExternalProvider provider, string calendarName, string? title, bool busyOnly,
        DateTimeOffset startsAt, DateTimeOffset endsAt, bool allDay, string? colorHex, DateTimeOffset now)
    {
        FamilyId = familyId;
        OwnerUserId = ownerUserId;
        SourceKey = Required(sourceKey, MaxSourceKey, "external_event.source_key_invalid");
        Update(provider, calendarName, title, busyOnly, startsAt, endsAt, allDay, colorHex, now);
    }

    public Guid FamilyId { get; private set; }
    public Guid OwnerUserId { get; private set; }

    /// <summary>The app's stable key for the occurrence (calendar + event + start); opaque to the server.</summary>
    public string SourceKey { get; private set; } = default!;
    public ExternalProvider Provider { get; private set; }
    public string CalendarName { get; private set; } = default!;

    /// <summary>Null when the parent shares only that they are busy.</summary>
    public string? Title { get; private set; }
    public bool BusyOnly { get; private set; }
    public DateTimeOffset StartsAt { get; private set; }
    public DateTimeOffset EndsAt { get; private set; }
    public bool AllDay { get; private set; }

    /// <summary>The calendar's color as <c>#RRGGBB</c>, if the phone reported one.</summary>
    public string? ColorHex { get; private set; }
    public DateTimeOffset SyncedAt { get; private set; }

    public void Update(ExternalProvider provider, string calendarName, string? title, bool busyOnly, DateTimeOffset startsAt, DateTimeOffset endsAt,
        bool allDay, string? colorHex, DateTimeOffset now)
    {
        if (!Enum.IsDefined(provider))
        {
            throw new DomainException("external_event.provider_invalid", "Unknown calendar provider.");
        }

        if (endsAt < startsAt)
        {
            throw new DomainException("external_event.end_before_start", "Event end must be after its start.");
        }

        Provider = provider;
        CalendarName = Required(calendarName, MaxCalendarName, "external_event.calendar_invalid");
        BusyOnly = busyOnly;
        var trimmed = title?.Trim();
        Title = busyOnly || string.IsNullOrEmpty(trimmed) ? null : trimmed.Length > MaxTitle ? trimmed[..MaxTitle] : trimmed;
        StartsAt = startsAt.ToUniversalTime();
        EndsAt = endsAt.ToUniversalTime();
        AllDay = allDay;
        ColorHex = colorHex is { Length: 7 } c && c[0] == '#' && c[1..].All(Uri.IsHexDigit) ? c.ToUpperInvariant() : null;
        SyncedAt = now;
    }

    public bool Overlaps(DateTimeOffset start, DateTimeOffset end) => StartsAt < end && start < (EndsAt > StartsAt ? EndsAt : StartsAt.AddMinutes(1));

    private static string Required(string value, int max, string code)
    {
        var v = value?.Trim();
        if (string.IsNullOrEmpty(v) || v.Length > max)
        {
            throw new DomainException(code, $"Must be 1-{max} characters.");
        }

        return v;
    }
}

/// <summary>A parent's private subscription link (iCal/webcal) to the family's Hally events, for Google, iCloud or
/// Outlook on a computer. Only the token's hash is stored; a new link replaces the old one.</summary>
public class CalendarFeed : Entity
{
    private CalendarFeed() { }

    public CalendarFeed(Guid familyId, Guid userId, string tokenHash, DateTimeOffset now)
    {
        FamilyId = familyId;
        UserId = userId;
        TokenHash = tokenHash;
        CreatedAt = now;
    }

    public Guid FamilyId { get; private set; }
    public Guid UserId { get; private set; }
    public string TokenHash { get; private set; } = default!;
    public DateTimeOffset? LastFetchedAt { get; private set; }
    public int FetchCount { get; private set; }

    public void Fetched(DateTimeOffset now)
    {
        FetchCount++;
        LastFetchedAt = now;
    }
}
