using Hally.Domain.Common;

namespace Hally.Domain.Planning;

/// <summary>How a calendar event repeats. Occurrences are computed on read, in the family's time zone.</summary>
public enum EventRepeat
{
    None,
    Daily,
    Weekly,
    Monthly,
}

public class CalendarEvent : Entity
{
    private CalendarEvent() { }

    public CalendarEvent(Guid familyId, Guid createdByUserId, string title, DateTimeOffset startsAt, DateTimeOffset? endsAt,
        bool allDay, string? location, Guid? childId, Guid? sourceProposalId = null)
    {
        FamilyId = familyId;
        CreatedByUserId = createdByUserId;
        SourceProposalId = sourceProposalId;
        Update(title, startsAt, endsAt, allDay, location, childId);
    }

    public Guid FamilyId { get; private set; }
    public Guid CreatedByUserId { get; private set; }
    public string Title { get; private set; } = default!;
    public DateTimeOffset StartsAt { get; private set; }
    public DateTimeOffset? EndsAt { get; private set; }
    public bool AllDay { get; private set; }
    public string? Location { get; private set; }
    public Guid? ChildId { get; private set; }
    public Guid? SourceProposalId { get; private set; }
    public EventRepeat Repeat { get; private set; }

    /// <summary>Last day (family local date, inclusive) an occurrence may start on. Null repeats forever.</summary>
    public DateOnly? RepeatUntil { get; private set; }

    /// <summary>Start of the first occurrence. Differs from <see cref="StartsAt"/> on occurrence copies.</summary>
    public DateTimeOffset SeriesStartsAt => _seriesStartsAt ?? StartsAt;

    private DateTimeOffset? _seriesStartsAt;

    /// <summary>Safety cap for expanding a series within one query window.</summary>
    private const int MaxOccurrences = 1000;

    public void Update(string title, DateTimeOffset startsAt, DateTimeOffset? endsAt, bool allDay, string? location, Guid? childId)
    {
        if (string.IsNullOrWhiteSpace(title) || title.Trim().Length > 200)
        {
            throw new DomainException("event.title_invalid", "Event title must be 1-200 characters.");
        }

        if (endsAt is { } end && end < startsAt)
        {
            throw new DomainException("event.end_before_start", "Event end must be after its start.");
        }

        Title = title.Trim();
        StartsAt = startsAt.ToUniversalTime(); // PostgreSQL timestamptz accepts UTC only
        EndsAt = endsAt?.ToUniversalTime();
        AllDay = allDay;
        Location = string.IsNullOrWhiteSpace(location) ? null : location.Trim();
        ChildId = childId;
    }

    public void SetRepeat(EventRepeat repeat, DateOnly? until)
    {
        if (!Enum.IsDefined(repeat))
        {
            throw new DomainException("event.repeat_invalid", "Unknown repeat rule.");
        }

        // Compare with a day of slack: StartsAt is UTC, RepeatUntil is the family's local date.
        if (repeat != EventRepeat.None && until is { } u && u < DateOnly.FromDateTime(StartsAt.UtcDateTime).AddDays(-1))
        {
            throw new DomainException("event.repeat_until_before_start", "A series must not end before it starts.");
        }

        Repeat = repeat;
        RepeatUntil = repeat == EventRepeat.None ? null : until;
    }

    /// <summary>
    /// The occurrences of this event that overlap [start, end). A one-off event yields itself; a series yields
    /// detached copies whose <see cref="StartsAt"/>/<see cref="EndsAt"/> are shifted, keeping the wall-clock time
    /// in <paramref name="zone"/> (so 11:30 stays 11:30 across DST changes).
    /// </summary>
    public IEnumerable<CalendarEvent> OccurrencesOverlapping(DateTimeOffset start, DateTimeOffset end, TimeZoneInfo zone)
    {
        if (Repeat == EventRepeat.None)
        {
            if (Overlaps(start, end))
            {
                yield return this;
            }

            yield break;
        }

        var length = EffectiveEnd - StartsAt;
        var firstLocal = TimeZoneInfo.ConvertTime(StartsAt, zone).DateTime;
        var skip = Math.Max(0, Repeat switch
        {
            EventRepeat.Daily => (int)Math.Floor((start - length - StartsAt).TotalDays) - 1,
            EventRepeat.Weekly => (int)Math.Floor((start - length - StartsAt).TotalDays / 7) - 1,
            _ => ((start.Year - StartsAt.Year) * 12) + start.Month - StartsAt.Month - 2,
        });

        for (var i = skip; i < skip + MaxOccurrences; i++)
        {
            var local = Repeat switch
            {
                EventRepeat.Daily => firstLocal.AddDays(i),
                EventRepeat.Weekly => firstLocal.AddDays(7 * i),
                _ => firstLocal.AddMonths(i),
            };
            if (RepeatUntil is { } until && DateOnly.FromDateTime(local) > until)
            {
                yield break;
            }

            var occurrence = new DateTimeOffset(local, zone.GetUtcOffset(local)).ToUniversalTime();
            if (occurrence >= end)
            {
                yield break;
            }

            if (occurrence + length > start)
            {
                yield return i == 0 ? this : CopyAt(occurrence);
            }
        }
    }

    private CalendarEvent CopyAt(DateTimeOffset occurrence)
    {
        var copy = (CalendarEvent)MemberwiseClone();
        copy._seriesStartsAt = StartsAt;
        copy.EndsAt = EndsAt is { } e ? occurrence + (e - StartsAt) : null;
        copy.StartsAt = occurrence;
        return copy;
    }

    public DateTimeOffset EffectiveEnd => EndsAt ?? (AllDay ? StartsAt.AddDays(1) : StartsAt.AddHours(1));

    public bool Overlaps(DateTimeOffset start, DateTimeOffset end) => StartsAt < end && start < EffectiveEnd;
}
