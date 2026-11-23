using Hally.Domain.Common;

namespace Hally.Domain.ScreenTime;

/// <summary>
/// One stretch of screen time for a child, started and stopped by hand from the app. A running session has no
/// <see cref="EndedAt"/>; a child has at most one running session (a partial unique index enforces it).
/// Only the times are kept: Hally does not watch or restrict the device itself.
/// </summary>
public class ScreenTimeSession : Entity
{
    /// <summary>A forgotten timer stops counting after this long, so one missed "Stop" does not ruin the week.</summary>
    public static readonly TimeSpan MaxLength = TimeSpan.FromHours(8);

    private ScreenTimeSession() { }

    public ScreenTimeSession(Guid familyId, Guid childId, Guid startedByUserId, DateTimeOffset now)
    {
        FamilyId = familyId;
        ChildId = childId;
        StartedByUserId = startedByUserId;
        StartedAt = now;
        CreatedAt = now;
    }

    public Guid FamilyId { get; private set; }
    public Guid ChildId { get; private set; }
    public DateTimeOffset StartedAt { get; private set; }
    public DateTimeOffset? EndedAt { get; private set; }

    /// <summary>Null once that adult has deleted their account.</summary>
    public Guid? StartedByUserId { get; private set; }

    public Guid? EndedByUserId { get; private set; }

    public bool IsRunning => EndedAt is null;

    /// <summary>When the session stops counting: its end, or <see cref="MaxLength"/> after the start.</summary>
    public DateTimeOffset CountsUntil(DateTimeOffset now)
    {
        var end = EndedAt ?? now;
        var cap = StartedAt + MaxLength;
        return end < cap ? end : cap;
    }

    /// <param name="userId">Who pressed Stop; null when the timer stopped by itself.</param>
    public void Stop(Guid? userId, DateTimeOffset now)
    {
        if (!IsRunning)
        {
            throw new DomainException("screen_time.not_running", "This timer is already stopped.");
        }

        EndedAt = CountsUntil(now < StartedAt ? StartedAt : now);
        EndedByUserId = userId;
    }

    /// <summary>A finished stretch added by hand ("we forgot to start the timer"), ending now.</summary>
    public static ScreenTimeSession Manual(Guid familyId, Guid childId, Guid userId, TimeSpan length, DateTimeOffset now)
    {
        if (length <= TimeSpan.Zero || length > MaxLength)
        {
            throw new DomainException("screen_time.length_invalid", $"A manual entry must be 1-{(int)MaxLength.TotalMinutes} minutes.");
        }

        var session = new ScreenTimeSession(familyId, childId, userId, now - length);
        session.EndedAt = now;
        session.EndedByUserId = userId;
        session.CreatedAt = now;
        return session;
    }

    /// <summary>The part of this session that falls in [from, to).</summary>
    public TimeSpan Within(DateTimeOffset from, DateTimeOffset to, DateTimeOffset now)
    {
        var start = StartedAt > from ? StartedAt : from;
        var until = CountsUntil(now);
        var end = until < to ? until : to;
        return end > start ? end - start : TimeSpan.Zero;
    }
}
