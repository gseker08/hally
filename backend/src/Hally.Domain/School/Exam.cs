using Hally.Domain.Common;

namespace Hally.Domain.School;

/// <summary>How the exam went, in the parents' words. Never shown as red; "Hard" is just a note.</summary>
public enum ExamOutcome
{
    Hard,
    Good,
    Great,
}

/// <summary>
/// A child's upcoming exam ("Matematik, 27 Kasım, 2. ders, Kesirler"). It owns one calendar event (tagged with the
/// child) so the exam shows in the calendar, on Today and in the morning summary. When <see cref="StudyDaysBefore"/>
/// is set, the parents get a "Çalışma zamanı" note each evening from that many days before the exam. After the exam a
/// parent can note how it went, an optional score, and give cherries once. Results are for parents only.
/// </summary>
public class Exam : Entity
{
    public const int MaxSubject = 40;
    public const int MaxTopics = 200;
    public const int MaxSlot = 20;
    public const int MaxCherries = 50;
    public static readonly int[] StudyDayChoices = [1, 2, 3, 7];

    private Exam() { }

    public Exam(Guid familyId, Guid childId, Guid createdByUserId, DateTimeOffset now)
    {
        FamilyId = familyId;
        ChildId = childId;
        CreatedByUserId = createdByUserId;
        CreatedAt = now;
    }

    public Guid FamilyId { get; private set; }
    public Guid ChildId { get; private set; }
    public Guid? CreatedByUserId { get; private set; }

    /// <summary>"Matematik".</summary>
    public string Subject { get; private set; } = default!;

    /// <summary>"Kesirler, ondalık sayılar".</summary>
    public string? Topics { get; private set; }

    /// <summary>The family-local day of the exam.</summary>
    public DateOnly Date { get; private set; }

    /// <summary>Free text for when in the day: "2. ders", "10:30".</summary>
    public string? Slot { get; private set; }

    /// <summary>Evening study notes start this many days before the exam; null turns them off.</summary>
    public int? StudyDaysBefore { get; private set; }

    /// <summary>The calendar event this exam keeps in step. Deleting the event deletes the exam.</summary>
    public Guid? EventId { get; private set; }

    public ExamOutcome? Outcome { get; private set; }

    /// <summary>Optional score out of 100.</summary>
    public int? Score { get; private set; }

    /// <summary>Cherries given for the result (once).</summary>
    public int Cherries { get; private set; }

    public DateTimeOffset? ResultAt { get; private set; }
    public Guid? ResultByUserId { get; private set; }

    public bool HasResult => Outcome is not null;

    public void Update(Guid childId, string subject, string? topics, DateOnly date, string? slot, int? studyDaysBefore)
    {
        subject = (subject ?? "").Trim();
        if (subject.Length is 0 or > MaxSubject)
        {
            throw new DomainException("exam.subject_invalid", $"Subject must be 1-{MaxSubject} characters.");
        }

        topics = string.IsNullOrWhiteSpace(topics) ? null : topics.Trim();
        if (topics is { Length: > MaxTopics })
        {
            throw new DomainException("exam.topics_invalid", $"Topics must be at most {MaxTopics} characters.");
        }

        slot = string.IsNullOrWhiteSpace(slot) ? null : slot.Trim();
        if (slot is { Length: > MaxSlot })
        {
            throw new DomainException("exam.slot_invalid", $"Time must be at most {MaxSlot} characters.");
        }

        if (studyDaysBefore is { } d && !StudyDayChoices.Contains(d))
        {
            throw new DomainException("exam.study_days_invalid", "Study reminders start 1, 2, 3 or 7 days before.");
        }

        ChildId = childId;
        Subject = subject;
        Topics = topics;
        Date = date;
        Slot = slot;
        StudyDaysBefore = studyDaysBefore;
    }

    public void LinkEvent(Guid eventId) => EventId = eventId;

    /// <summary>The first and last evening with a study note, or null when off or already past.</summary>
    public (DateOnly From, DateOnly To)? StudyWindow => StudyDaysBefore is { } d ? (Date.AddDays(-d), Date.AddDays(-1)) : null;

    public bool IsStudyDay(DateOnly day) => StudyWindow is { } w && day >= w.From && day <= w.To;

    /// <summary>Records how it went. Returns the cherries to add now: the first time cherries are given; later changes
    /// keep the cherries already given (they are in the jar and may be spent).</summary>
    public int SetResult(ExamOutcome outcome, int? score, int cherries, Guid userId, DateOnly today, DateTimeOffset now)
    {
        if (!Enum.IsDefined(outcome))
        {
            throw new DomainException("exam.outcome_invalid", "Unknown outcome.");
        }

        if (today < Date)
        {
            throw new DomainException("exam.not_yet", "The exam has not happened yet.");
        }

        if (score is < 0 or > 100)
        {
            throw new DomainException("exam.score_invalid", "Score must be 0-100.");
        }

        if (cherries is < 0 or > MaxCherries)
        {
            throw new DomainException("exam.cherries_invalid", $"Cherries must be 0-{MaxCherries}.");
        }

        Outcome = outcome;
        Score = score;
        ResultAt = now;
        ResultByUserId = userId;
        if (Cherries > 0 || cherries == 0)
        {
            return 0;
        }

        Cherries = cherries;
        return cherries;
    }

    /// <summary>The calendar title, in the creator's language.</summary>
    public string EventTitle(bool turkish) => turkish ? $"📝 {Subject} sınavı" : $"📝 {Subject} exam";
}
