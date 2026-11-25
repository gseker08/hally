using Hally.Domain.Common;

namespace Hally.Domain.Mood;

public enum Mood
{
    Great,
    Good,
    Okay,
    Sad,
    Angry,
    Tired,
}

/// <summary>Why the child feels so (optional, any number).</summary>
public enum MoodReason
{
    Friends,
    School,
    Home,
    Play,
}

/// <summary>
/// The child's daily "Bugün nasılsın?" answer from child mode. One per child per day (answering again changes it).
/// Only parents see it; it is deleted after <see cref="RetentionDays"/> days. Not a medical assessment.
/// </summary>
public class MoodCheck : Entity
{
    public const int RetentionDays = 90;

    private MoodCheck() { }

    public MoodCheck(Guid familyId, Guid childId, DateOnly day, DateTimeOffset now)
    {
        FamilyId = familyId;
        ChildId = childId;
        Day = day;
        CreatedAt = now;
    }

    public Guid FamilyId { get; private set; }
    public Guid ChildId { get; private set; }
    public DateOnly Day { get; private set; }
    public Mood Mood { get; private set; }
    public List<MoodReason> Reasons { get; private set; } = [];

    public static bool IsHard(Mood mood) => mood is Mood.Sad or Mood.Angry;

    public void Answer(Mood mood, IEnumerable<MoodReason> reasons)
    {
        Mood = mood;
        Reasons = reasons.Distinct().OrderBy(r => r).ToList();
    }
}
