using Hally.Domain.Common;

namespace Hally.Domain.Health;

/// <summary>
/// A medicine a child is taking, with the spacing the parents entered (from the doctor or the leaflet).
/// Hally never suggests a dose or an interval: it only records doses and warns when one comes sooner than the
/// parents' own rule allows, so two parents do not give the same dose twice.
/// </summary>
public class Medication : Entity
{
    public const int MinInterval = 30;
    public const int MaxInterval = 72 * 60;

    private Medication() { }

    public Medication(Guid familyId, Guid childId, Guid createdByUserId, string name, string? dose, int minIntervalMinutes,
        int? maxDosesPerDay, bool remindNextDose, string? notes, DateTimeOffset now)
    {
        FamilyId = familyId;
        ChildId = childId;
        CreatedByUserId = createdByUserId;
        CreatedAt = now;
        Update(name, dose, minIntervalMinutes, maxDosesPerDay, remindNextDose, notes, true);
    }

    public Guid FamilyId { get; private set; }
    public Guid ChildId { get; private set; }
    public Guid? CreatedByUserId { get; private set; }
    public string Name { get; private set; } = default!;

    /// <summary>Free text such as "5 ml" or "1 tablet".</summary>
    public string? Dose { get; private set; }

    /// <summary>Doses closer together than this get a warning.</summary>
    public int MinIntervalMinutes { get; private set; }

    /// <summary>Most doses in any 24 hours; null for no limit.</summary>
    public int? MaxDosesPerDay { get; private set; }

    /// <summary>Remind the adults when the next dose may be given.</summary>
    public bool RemindNextDose { get; private set; }

    public string? Notes { get; private set; }

    /// <summary>False once the course is over; kept for the history.</summary>
    public bool Active { get; private set; }

    public void Update(string name, string? dose, int minIntervalMinutes, int? maxDosesPerDay, bool remindNextDose, string? notes, bool active)
    {
        if (string.IsNullOrWhiteSpace(name) || name.Trim().Length > 60)
        {
            throw new DomainException("medication.name_invalid", "Name must be 1-60 characters.");
        }

        if (dose is { Length: > 40 } || notes is { Length: > 300 })
        {
            throw new DomainException("medication.text_too_long", "Dose is at most 40 and notes at most 300 characters.");
        }

        if (minIntervalMinutes is < MinInterval or > MaxInterval)
        {
            throw new DomainException("medication.interval_invalid", $"Interval must be {MinInterval}-{MaxInterval} minutes.");
        }

        if (maxDosesPerDay is < 1 or > 24)
        {
            throw new DomainException("medication.max_invalid", "Max doses per day must be 1-24.");
        }

        Name = name.Trim();
        Dose = string.IsNullOrWhiteSpace(dose) ? null : dose.Trim();
        MinIntervalMinutes = minIntervalMinutes;
        MaxDosesPerDay = maxDosesPerDay;
        RemindNextDose = remindNextDose;
        Notes = string.IsNullOrWhiteSpace(notes) ? null : notes.Trim();
        Active = active;
    }

    /// <summary>Why a dose at <paramref name="at"/> would break the parents' rule, or null when it is fine.</summary>
    /// <param name="recent">Doses of this medication from the last 24 hours (or more).</param>
    public DoseWarning? Check(IReadOnlyCollection<MedicationDose> recent, DateTimeOffset at)
    {
        var interval = TimeSpan.FromMinutes(MinIntervalMinutes);
        var tooClose = recent.Where(d => (d.GivenAt - at).Duration() < interval).OrderByDescending(d => d.GivenAt).FirstOrDefault();
        if (tooClose is not null)
        {
            return new DoseWarning(DoseWarningKind.TooSoon, tooClose, NextAllowedAt(recent, at));
        }

        if (MaxDosesPerDay is { } max && recent.Count(d => d.GivenAt > at.AddHours(-24) && d.GivenAt <= at) >= max)
        {
            return new DoseWarning(DoseWarningKind.DailyLimit, recent.OrderByDescending(d => d.GivenAt).First(), NextAllowedAt(recent, at));
        }

        return null;
    }

    /// <summary>The earliest time after the latest dose that meets both the interval and the daily limit.</summary>
    public DateTimeOffset? NextAllowedAt(IReadOnlyCollection<MedicationDose> recent, DateTimeOffset now)
    {
        var past = recent.Where(d => d.GivenAt <= now).OrderByDescending(d => d.GivenAt).ToList();
        if (past.Count == 0)
        {
            return null;
        }

        var next = past[0].GivenAt.AddMinutes(MinIntervalMinutes);
        if (MaxDosesPerDay is { } max && past.Count >= max)
        {
            // The oldest of the last `max` doses must leave the 24-hour window.
            var limitEnds = past[max - 1].GivenAt.AddHours(24);
            if (limitEnds > next)
            {
                next = limitEnds;
            }
        }

        return next;
    }
}

public enum DoseWarningKind
{
    TooSoon,
    DailyLimit,
}

public record DoseWarning(DoseWarningKind Kind, MedicationDose Nearest, DateTimeOffset? NextAllowedAt);

/// <summary>One dose that was given.</summary>
public class MedicationDose : Entity
{
    private MedicationDose() { }

    public MedicationDose(Medication medication, Guid givenByUserId, DateTimeOffset givenAt, string? note, bool overrodeWarning, DateTimeOffset now)
    {
        if (givenAt > now.AddMinutes(5))
        {
            throw new DomainException("medication.dose_in_future", "A dose cannot be recorded in the future.");
        }

        if (note is { Length: > 200 })
        {
            throw new DomainException("medication.text_too_long", "A note is at most 200 characters.");
        }

        MedicationId = medication.Id;
        FamilyId = medication.FamilyId;
        ChildId = medication.ChildId;
        GivenByUserId = givenByUserId;
        GivenAt = givenAt;
        Note = string.IsNullOrWhiteSpace(note) ? null : note.Trim();
        OverrodeWarning = overrodeWarning;
        CreatedAt = now;
    }

    public Guid MedicationId { get; private set; }
    public Guid FamilyId { get; private set; }
    public Guid ChildId { get; private set; }
    public Guid? GivenByUserId { get; private set; }
    public DateTimeOffset GivenAt { get; private set; }
    public string? Note { get; private set; }

    /// <summary>The adult saw the "too soon" warning and saved anyway.</summary>
    public bool OverrodeWarning { get; private set; }
}
