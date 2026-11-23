using Hally.Domain.Common;

namespace Hally.Domain.Habits;

/// <summary>A small daily habit for one child ("Diş fırçalama", "Yatağını topla") on chosen weekdays.</summary>
public class Habit : Entity
{
    /// <summary>Monday is bit 0, Sunday bit 6.</summary>
    public const int EveryDay = 0b111_1111;

    private Habit() { }

    public Habit(Guid familyId, Guid childId, string title, int days, DateTimeOffset now)
    {
        if (string.IsNullOrWhiteSpace(title) || title.Trim().Length > 60)
        {
            throw new DomainException("habit.title_invalid", "Title must be 1-60 characters.");
        }

        if (days is < 1 or > EveryDay)
        {
            throw new DomainException("habit.days_invalid", "Pick at least one weekday.");
        }

        FamilyId = familyId;
        ChildId = childId;
        Title = title.Trim();
        Days = days;
        CreatedAt = now;
    }

    public Guid FamilyId { get; private set; }
    public Guid ChildId { get; private set; }
    public string Title { get; private set; } = default!;
    public int Days { get; private set; }

    public bool IsScheduled(DateOnly day) => (Days & (1 << (((int)day.DayOfWeek + 6) % 7))) != 0;

    /// <summary>
    /// Scheduled days in a row that were checked, counting back from <paramref name="today"/>. Unscheduled days are
    /// skipped; an unchecked today does not break the streak yet. Days before <paramref name="since"/> do not count.
    /// </summary>
    public int Streak(ISet<DateOnly> checkedDays, DateOnly today, DateOnly since)
    {
        var streak = 0;
        for (var d = today; d >= since; d = d.AddDays(-1))
        {
            if (!IsScheduled(d))
            {
                continue;
            }

            if (checkedDays.Contains(d))
            {
                streak++;
            }
            else if (d != today)
            {
                break;
            }
        }

        return streak;
    }

    /// <summary>The longest run of checked scheduled days.</summary>
    public int Best(ISet<DateOnly> checkedDays, DateOnly today, DateOnly since)
    {
        int best = 0, run = 0;
        for (var d = since; d <= today; d = d.AddDays(1))
        {
            if (!IsScheduled(d))
            {
                continue;
            }

            if (checkedDays.Contains(d))
            {
                best = Math.Max(best, ++run);
            }
            else if (d != today)
            {
                run = 0;
            }
        }

        return best;
    }
}

/// <summary>A habit done on one family-local day.</summary>
public class HabitCheck : Entity
{
    private HabitCheck() { }

    public HabitCheck(Habit habit, DateOnly day, Guid userId, DateTimeOffset now)
    {
        FamilyId = habit.FamilyId;
        HabitId = habit.Id;
        Day = day;
        ByUserId = userId;
        CreatedAt = now;
    }

    public Guid FamilyId { get; private set; }
    public Guid HabitId { get; private set; }
    public DateOnly Day { get; private set; }
    public Guid? ByUserId { get; private set; }
}
