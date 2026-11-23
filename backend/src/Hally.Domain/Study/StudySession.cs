using Hally.Domain.Common;

namespace Hally.Domain.Study;

public enum StudyKind
{
    Homework,
    Reading,
}

/// <summary>
/// One stretch of homework or reading for a child, started and stopped by hand. A running session has no
/// <see cref="EndedAt"/>; a child has at most one running session (a partial unique index enforces it).
/// The daily goal is a minimum ("at least 30 minutes"), unlike the screen time limit.
/// </summary>
public class StudySession : Entity
{
    /// <summary>A forgotten timer stops counting after this long.</summary>
    public static readonly TimeSpan MaxLength = TimeSpan.FromHours(4);

    private StudySession() { }

    public StudySession(Guid familyId, Guid childId, Guid userId, StudyKind kind, DateTimeOffset now)
    {
        FamilyId = familyId;
        ChildId = childId;
        StartedByUserId = userId;
        Kind = kind;
        StartedAt = now;
        CreatedAt = now;
    }

    public Guid FamilyId { get; private set; }
    public Guid ChildId { get; private set; }
    public StudyKind Kind { get; private set; }
    public DateTimeOffset StartedAt { get; private set; }
    public DateTimeOffset? EndedAt { get; private set; }
    public Guid? StartedByUserId { get; private set; }
    public Guid? EndedByUserId { get; private set; }

    /// <summary>What was read or worked on ("Küçük Prens, 20 sayfa").</summary>
    public string? Note { get; private set; }

    public bool IsRunning => EndedAt is null;

    public DateTimeOffset CountsUntil(DateTimeOffset now)
    {
        var end = EndedAt ?? now;
        var cap = StartedAt + MaxLength;
        return end < cap ? end : cap;
    }

    /// <summary>Running and not yet past <see cref="MaxLength"/>.</summary>
    public bool IsCounting(DateTimeOffset now) => IsRunning && CountsUntil(now) >= now;

    public void Stop(Guid? userId, string? note, DateTimeOffset now)
    {
        if (!IsRunning)
        {
            throw new DomainException("study.not_running", "This timer is already stopped.");
        }

        EndedAt = CountsUntil(now < StartedAt ? StartedAt : now);
        EndedByUserId = userId;
        SetNote(note);
    }

    /// <summary>A finished stretch added by hand, ending now.</summary>
    public static StudySession Manual(Guid familyId, Guid childId, Guid userId, StudyKind kind, TimeSpan length, string? note, DateTimeOffset now)
    {
        if (length <= TimeSpan.Zero || length > MaxLength)
        {
            throw new DomainException("study.length_invalid", $"A manual entry must be 1-{(int)MaxLength.TotalMinutes} minutes.");
        }

        var session = new StudySession(familyId, childId, userId, kind, now - length) { EndedAt = now, EndedByUserId = userId, CreatedAt = now };
        session.SetNote(note);
        return session;
    }

    private void SetNote(string? note)
    {
        if (note is { Length: > 120 })
        {
            throw new DomainException("study.note_too_long", "Note can be up to 120 characters.");
        }

        if (!string.IsNullOrWhiteSpace(note))
        {
            Note = note.Trim();
        }
    }

    /// <summary>The part of this session that falls in [from, to).</summary>
    public TimeSpan Within(DateTimeOffset from, DateTimeOffset to, DateTimeOffset now)
    {
        var start = StartedAt > from ? StartedAt : from;
        var until = CountsUntil(now);
        var end = until < to ? until : to;
        return end > start ? end - start : TimeSpan.Zero;
    }

    /// <summary>
    /// Days in a row the goal was met, counting back from today; today counts once it is met, and an unmet today
    /// does not break the streak yet (the day is not over).
    /// </summary>
    /// <param name="metByDay">Goal met per day, oldest first, ending with today.</param>
    public static int Streak(IReadOnlyList<bool> metByDay)
    {
        var streak = 0;
        for (var i = metByDay.Count - 1; i >= 0; i--)
        {
            if (metByDay[i])
            {
                streak++;
            }
            else if (i != metByDay.Count - 1)
            {
                break;
            }
        }

        return streak;
    }
}
