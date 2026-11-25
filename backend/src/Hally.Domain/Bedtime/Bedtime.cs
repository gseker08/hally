using System.Text.Json;
using Hally.Domain.Common;

namespace Hally.Domain.Bedtime;

public sealed record BedtimeStep(string Title, string Emoji);

/// <summary>
/// "Uyku öncesi rutini": the steps a child checks off in order on their own phone each evening, from a time the
/// parents set. When the last step is done the child gets cherries, the parents a "yatağında" note, and (optionally)
/// the phone stays locked until morning.
/// </summary>
public class BedtimeRoutine : Entity
{
    public const int MaxSteps = 8;
    public const int MaxCherries = 10;

    /// <summary>The steps open this long before the routine's time.</summary>
    public static readonly TimeSpan OpensBefore = TimeSpan.FromMinutes(30);

    /// <summary>A phone locked after the routine opens again at this family-local time.</summary>
    public static readonly TimeOnly MorningUnlock = new(7, 0);

    /// <summary>Before this hour a night still belongs to the previous evening.</summary>
    public const int EveningStartsHour = 12;

    private BedtimeRoutine() { }

    public BedtimeRoutine(Guid familyId, Guid childId, DateTimeOffset now)
    {
        FamilyId = familyId;
        ChildId = childId;
        CreatedAt = now;
    }

    public Guid FamilyId { get; private set; }
    public Guid ChildId { get; private set; }
    public TimeOnly Time { get; private set; } = new(20, 30);
    public string StepsJson { get; private set; } = "[]";
    public bool Enabled { get; private set; } = true;
    public bool LockUntilMorning { get; private set; } = true;
    public int Cherries { get; private set; } = 3;

    public IReadOnlyList<BedtimeStep> Steps => JsonSerializer.Deserialize<List<BedtimeStep>>(StepsJson) ?? [];

    public void Update(TimeOnly time, IReadOnlyList<BedtimeStep> steps, bool enabled, bool lockUntilMorning, int cherries)
    {
        if (steps.Count is 0 or > MaxSteps)
        {
            throw new DomainException("bedtime.steps_invalid", $"A routine has 1-{MaxSteps} steps.");
        }

        var clean = steps.Select(s => new BedtimeStep(s.Title?.Trim() ?? "", string.IsNullOrWhiteSpace(s.Emoji) ? "⭐" : s.Emoji.Trim())).ToList();
        if (clean.Any(s => s.Title.Length is 0 or > 40 || s.Emoji.Length > 8))
        {
            throw new DomainException("bedtime.step_invalid", "Each step needs a title of 1-40 characters.");
        }

        if (cherries is < 0 or > MaxCherries)
        {
            throw new DomainException("bedtime.cherries_invalid", $"Cherries must be 0-{MaxCherries}.");
        }

        if (time.Hour < 17 && time.Hour >= 5)
        {
            throw new DomainException("bedtime.time_invalid", "Bedtime must be in the evening (17:00-04:59).");
        }

        Time = new TimeOnly(time.Hour, time.Minute);
        StepsJson = JsonSerializer.Serialize(clean);
        Enabled = enabled;
        LockUntilMorning = lockUntilMorning;
        Cherries = cherries;
    }

    /// <summary>The evening a family-local moment belongs to: 01:30 on Tuesday is still Monday's night.</summary>
    public static DateOnly EveningOf(DateTimeOffset local) =>
        DateOnly.FromDateTime(local.DateTime).AddDays(local.Hour < EveningStartsHour ? -1 : 0);

    /// <summary>Whether the steps can be checked now: from <see cref="OpensBefore"/> before the time until morning.</summary>
    public bool IsOpen(DateTimeOffset local)
    {
        var evening = EveningOf(local);
        var start = evening.ToDateTime(Time) - OpensBefore;
        if (Time.Hour < EveningStartsHour)
        {
            start = start.AddDays(1); // a 00:30 bedtime is after midnight of that evening
        }

        var end = evening.AddDays(1).ToDateTime(MorningUnlock);
        return local.DateTime >= start && local.DateTime < end;
    }
}

/// <summary>One evening's progress: how many steps are done (they go in order) and when the last one was.</summary>
public class BedtimeRun : Entity
{
    private BedtimeRun() { }

    public BedtimeRun(Guid familyId, Guid childId, DateOnly evening, DateTimeOffset now)
    {
        FamilyId = familyId;
        ChildId = childId;
        Evening = evening;
        CreatedAt = now;
    }

    public Guid FamilyId { get; private set; }
    public Guid ChildId { get; private set; }
    public DateOnly Evening { get; private set; }
    public int Done { get; private set; }
    public DateTimeOffset? FinishedAt { get; private set; }

    /// <returns>true when this was the last step.</returns>
    public bool Check(int index, int total, DateTimeOffset now)
    {
        if (index < Done || FinishedAt is not null)
        {
            return false; // already done: a double tap
        }

        if (index != Done || index >= total)
        {
            throw new DomainException("bedtime.out_of_order", "Do the steps in order.");
        }

        Done++;
        if (Done < total)
        {
            return false;
        }

        FinishedAt = now;
        return true;
    }
}
