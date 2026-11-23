using Hally.Domain.Common;

namespace Hally.Domain.Sleep;

public enum SleepKind
{
    Night,
    Nap,
}

/// <summary>
/// One sleep of a child: "fell asleep" starts it, "woke up" ends it. A child has at most one open entry (a partial
/// unique index enforces it). Entries can also be added afterwards with both times.
/// </summary>
public class SleepEntry : Entity
{
    /// <summary>Longer than any real sleep; an entry left open stops counting here.</summary>
    public static readonly TimeSpan MaxLength = TimeSpan.FromHours(16);

    /// <summary>Sleep days run 06:00 to 06:00 family time, so a night that starts at 21:00 and one that starts at 00:30
    /// both count for the evening's day.</summary>
    public static readonly TimeSpan DayStartsAt = TimeSpan.FromHours(6);

    private SleepEntry() { }

    public SleepEntry(Guid familyId, Guid childId, Guid userId, SleepKind kind, DateTimeOffset startedAt, DateTimeOffset? endedAt, string? note, DateTimeOffset now)
    {
        if (startedAt > now.AddMinutes(5))
        {
            throw new DomainException("sleep.in_future", "Sleep cannot start in the future.");
        }

        FamilyId = familyId;
        ChildId = childId;
        Kind = kind;
        StartedAt = startedAt;
        StartedByUserId = userId;
        CreatedAt = now;
        SetNote(note);
        if (endedAt is { } end)
        {
            End(userId, end, now);
        }
    }

    public Guid FamilyId { get; private set; }
    public Guid ChildId { get; private set; }
    public SleepKind Kind { get; private set; }
    public DateTimeOffset StartedAt { get; private set; }
    public DateTimeOffset? EndedAt { get; private set; }
    public Guid? StartedByUserId { get; private set; }
    public Guid? EndedByUserId { get; private set; }
    public string? Note { get; private set; }

    public bool IsOpen => EndedAt is null;

    /// <summary>Night when it starts between 18:00 and 06:00 family time, otherwise a nap.</summary>
    public static SleepKind GuessKind(DateTimeOffset localStart) =>
        localStart.Hour >= 18 || localStart.Hour < 6 ? SleepKind.Night : SleepKind.Nap;

    /// <summary>The sleep day (06:00–06:00) a start time belongs to.</summary>
    public static DateOnly SleepDay(DateTimeOffset start, string timeZoneId) => FamilyTimeZone.LocalDate(start - DayStartsAt, timeZoneId);

    public void End(Guid? userId, DateTimeOffset at, DateTimeOffset now)
    {
        if (!IsOpen)
        {
            throw new DomainException("sleep.already_ended", "This sleep has already ended.");
        }

        if (at > now.AddMinutes(5))
        {
            throw new DomainException("sleep.in_future", "Wake-up cannot be in the future.");
        }

        if (at <= StartedAt)
        {
            throw new DomainException("sleep.end_before_start", "Wake-up must be after falling asleep.");
        }

        EndedAt = at - StartedAt > MaxLength ? StartedAt + MaxLength : at;
        EndedByUserId = userId;
    }

    public void SetNote(string? note)
    {
        if (note is { Length: > 200 })
        {
            throw new DomainException("sleep.note_too_long", "A note is at most 200 characters.");
        }

        Note = string.IsNullOrWhiteSpace(note) ? null : note.Trim();
    }

    public TimeSpan Duration(DateTimeOffset now)
    {
        var end = EndedAt ?? (now - StartedAt > MaxLength ? StartedAt + MaxLength : now);
        return end > StartedAt ? end - StartedAt : TimeSpan.Zero;
    }
}
