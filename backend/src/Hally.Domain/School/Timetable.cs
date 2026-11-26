using System.Text.Json;
using Hally.Domain.Common;

namespace Hally.Domain.School;

/// <summary>
/// A family's school settings: bell times (shared by all children), the evening "Yarın çantaya" time, items every
/// school day needs ("🍎 Beslenme"), whether the child's phone shows the bag list, and quiet days.
/// </summary>
public class SchoolPlan : Entity
{
    public const int MaxPeriods = 10;
    public const int MaxItems = 6;
    public const int MaxItemLength = 30;
    public static readonly TimeOnly DefaultReminder = new(19, 30);

    private SchoolPlan() { }

    public SchoolPlan(Guid familyId, DateTimeOffset now)
    {
        FamilyId = familyId;
        BellTimesJson = JsonSerializer.Serialize(DefaultBells);
        DailyItemsJson = "[]";
        ReminderTime = DefaultReminder;
        ChildPhone = true;
        QuietOnHolidays = true;
        CreatedAt = now;
    }

    public static readonly string[] DefaultBells = ["08:30", "09:20", "10:10", "11:00", "11:50", "13:00", "13:50"];

    public Guid FamilyId { get; private set; }
    public string BellTimesJson { get; private set; } = "[]";
    public string DailyItemsJson { get; private set; } = "[]";

    /// <summary>Family-local time of the evening note; null turns it off.</summary>
    public TimeOnly? ReminderTime { get; private set; }

    /// <summary>The child's own phone shows "Yarın çantana".</summary>
    public bool ChildPhone { get; private set; }

    /// <summary>No note before official holidays (Turkey) and the family's breaks.</summary>
    public bool QuietOnHolidays { get; private set; }

    public IReadOnlyList<string> BellTimes => JsonSerializer.Deserialize<List<string>>(BellTimesJson) ?? [];
    public IReadOnlyList<string> DailyItems => JsonSerializer.Deserialize<List<string>>(DailyItemsJson) ?? [];

    public void Update(IEnumerable<string>? bellTimes, IEnumerable<string>? dailyItems, TimeOnly? reminderTime, bool childPhone, bool quietOnHolidays)
    {
        var bells = (bellTimes ?? []).Select(b => b.Trim()).ToList();
        if (bells.Count > MaxPeriods)
        {
            throw new DomainException("school.too_many_periods", $"At most {MaxPeriods} periods.");
        }

        var times = new List<TimeOnly>();
        foreach (var b in bells)
        {
            if (!TimeOnly.TryParseExact(b, "HH:mm", out var t))
            {
                throw new DomainException("school.bell_invalid", "Bell times look like 08:30.");
            }

            if (times.Count > 0 && t <= times[^1])
            {
                throw new DomainException("school.bell_order", "Bell times must go up.");
            }

            times.Add(t);
        }

        BellTimesJson = JsonSerializer.Serialize(bells);
        DailyItemsJson = JsonSerializer.Serialize(Lesson.CheckItems(dailyItems));
        ReminderTime = reminderTime;
        ChildPhone = childPhone;
        QuietOnHolidays = quietOnHolidays;
    }

    /// <summary>Whether children go to school on <paramref name="day"/>: a weekday that is not a break and, with
    /// <see cref="QuietOnHolidays"/>, not an official holiday.</summary>
    public bool IsSchoolDay(DateOnly day, IEnumerable<SchoolBreak> breaks) =>
        day.DayOfWeek is not (DayOfWeek.Saturday or DayOfWeek.Sunday)
        && !breaks.Any(b => b.Covers(day))
        && !(QuietOnHolidays && TurkishHolidays.Contains(day));
}

/// <summary>A school break ("Ara tatil", 16–20 Kasım): no lessons, no evening notes.</summary>
public class SchoolBreak : Entity
{
    private SchoolBreak() { }

    public SchoolBreak(Guid familyId, string title, DateOnly from, DateOnly to, DateTimeOffset now)
    {
        title = (title ?? "").Trim();
        if (title.Length is 0 or > 40)
        {
            throw new DomainException("school.break_title_invalid", "Title must be 1-40 characters.");
        }

        if (to < from || to.DayNumber - from.DayNumber > 120)
        {
            throw new DomainException("school.break_range_invalid", "A break runs forward, at most 120 days.");
        }

        FamilyId = familyId;
        Title = title;
        From = from;
        To = to;
        CreatedAt = now;
    }

    public Guid FamilyId { get; private set; }
    public string Title { get; private set; } = default!;
    public DateOnly From { get; private set; }
    public DateOnly To { get; private set; }

    public bool Covers(DateOnly day) => day >= From && day <= To;
}

/// <summary>One period in a child's weekly timetable ("Perşembe 3. ders: Beden Eğitimi, 👟 Eşofman").</summary>
public class Lesson : Entity
{
    private Lesson() { }

    public Lesson(Guid familyId, Guid childId, int weekday, int period, DateTimeOffset now)
    {
        if (weekday is < 1 or > 5)
        {
            throw new DomainException("lesson.weekday_invalid", "Lessons are Monday (1) to Friday (5).");
        }

        if (period is < 1 or > SchoolPlan.MaxPeriods)
        {
            throw new DomainException("lesson.period_invalid", $"Period must be 1-{SchoolPlan.MaxPeriods}.");
        }

        FamilyId = familyId;
        ChildId = childId;
        Weekday = weekday;
        Period = period;
        CreatedAt = now;
    }

    public Guid FamilyId { get; private set; }
    public Guid ChildId { get; private set; }

    /// <summary>1 = Monday … 5 = Friday.</summary>
    public int Weekday { get; private set; }

    public int Period { get; private set; }
    public string Subject { get; private set; } = default!;
    public string ItemsJson { get; private set; } = "[]";

    public IReadOnlyList<string> Items => JsonSerializer.Deserialize<List<string>>(ItemsJson) ?? [];

    public void Set(string subject, IEnumerable<string>? items)
    {
        subject = (subject ?? "").Trim();
        if (subject.Length is 0 or > Exam.MaxSubject)
        {
            throw new DomainException("lesson.subject_invalid", $"Subject must be 1-{Exam.MaxSubject} characters.");
        }

        Subject = subject;
        ItemsJson = JsonSerializer.Serialize(CheckItems(items));
    }

    public static int WeekdayOf(DateOnly day) => day.DayOfWeek == DayOfWeek.Sunday ? 7 : (int)day.DayOfWeek;

    public static List<string> CheckItems(IEnumerable<string>? items)
    {
        var list = (items ?? []).Select(i => (i ?? "").Trim()).Where(i => i.Length > 0).Distinct().ToList();
        if (list.Count > SchoolPlan.MaxItems || list.Any(i => i.Length > SchoolPlan.MaxItemLength))
        {
            throw new DomainException("school.items_invalid", $"At most {SchoolPlan.MaxItems} items of {SchoolPlan.MaxItemLength} characters.");
        }

        return list;
    }
}

/// <summary>The bag for one school day: which items are packed, and when it was declared ready ("Hazırladık" or the
/// child's "Çantam hazır").</summary>
public class BagCheck : Entity
{
    private BagCheck() { }

    public BagCheck(Guid familyId, Guid childId, DateOnly day, DateTimeOffset now)
    {
        FamilyId = familyId;
        ChildId = childId;
        Day = day;
        CreatedAt = now;
    }

    public Guid FamilyId { get; private set; }
    public Guid ChildId { get; private set; }
    public DateOnly Day { get; private set; }
    public List<string> Packed { get; private set; } = [];
    public DateTimeOffset? ReadyAt { get; private set; }

    /// <summary>Who said ready: a parent or caregiver, or null for the child.</summary>
    public Guid? ReadyByUserId { get; private set; }

    public void Pack(string item, bool packed)
    {
        item = item.Trim();
        if (packed && !Packed.Contains(item))
        {
            Packed = [.. Packed, item];
        }
        else if (!packed)
        {
            Packed = Packed.Where(p => p != item).ToList();
        }
    }

    public void Ready(IEnumerable<string> items, Guid? byUserId, DateTimeOffset now)
    {
        Packed = Packed.Union(items).ToList();
        ReadyAt ??= now;
        ReadyByUserId ??= byUserId;
    }
}

/// <summary>Turkey's official holidays with no school. Fixed dates every year, plus the religious holidays (bayram
/// days, including the half-day eve) for the school years the app supports; add a year when it comes.</summary>
public static class TurkishHolidays
{
    private static readonly (int Month, int Day)[] Fixed = [(1, 1), (4, 23), (5, 1), (5, 19), (7, 15), (8, 30), (10, 29)];

    private static readonly DateOnly[] Bayrams =
    [
        // 2026: Ramazan Bayramı 20–22 March, Kurban Bayramı 27–30 May.
        new(2026, 3, 19),
        new(2026, 3, 20),
        new(2026, 3, 21),
        new(2026, 3, 22),
        new(2026, 5, 26),
        new(2026, 5, 27),
        new(2026, 5, 28),
        new(2026, 5, 29),
        new(2026, 5, 30),
        // 2027: Ramazan Bayramı 9–11 March, Kurban Bayramı 16–19 May.
        new(2027, 3, 8),
        new(2027, 3, 9),
        new(2027, 3, 10),
        new(2027, 3, 11),
        new(2027, 5, 15),
        new(2027, 5, 16),
        new(2027, 5, 17),
        new(2027, 5, 18),
        new(2027, 5, 19),
    ];

    public static bool Contains(DateOnly day) => Fixed.Contains((day.Month, day.Day)) || Bayrams.Contains(day);
}
