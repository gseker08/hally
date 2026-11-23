using Hally.Domain.Common;

namespace Hally.Domain.Health;

/// <summary>
/// The basics a parent is asked for at the doctor, school or a babysitter: blood type, allergies, ongoing conditions and the
/// family doctor. One per child. Hally only keeps what the parents typed; it gives no medical advice.
/// </summary>
public class HealthProfile : Entity
{
    public static readonly string[] BloodTypes = ["0+", "0-", "A+", "A-", "B+", "B-", "AB+", "AB-"];

    private HealthProfile() { }

    public HealthProfile(Guid familyId, Guid childId, DateTimeOffset now)
    {
        FamilyId = familyId;
        ChildId = childId;
        CreatedAt = now;
        UpdatedAt = now;
    }

    public Guid FamilyId { get; private set; }
    public Guid ChildId { get; private set; }
    public string? BloodType { get; private set; }
    public string? Allergies { get; private set; }
    public string? Conditions { get; private set; }
    public string? DoctorName { get; private set; }
    public string? DoctorPhone { get; private set; }
    public string? Notes { get; private set; }
    public DateTimeOffset UpdatedAt { get; private set; }

    public void Update(string? bloodType, string? allergies, string? conditions, string? doctorName, string? doctorPhone, string? notes, DateTimeOffset now)
    {
        bloodType = Clean(bloodType);
        if (bloodType is not null && !BloodTypes.Contains(bloodType))
        {
            throw new DomainException("health.blood_type_invalid", "Blood type must be one of " + string.Join(", ", BloodTypes) + ".");
        }

        allergies = Clean(allergies);
        conditions = Clean(conditions);
        doctorName = Clean(doctorName);
        doctorPhone = Clean(doctorPhone);
        notes = Clean(notes);
        if (allergies is { Length: > 300 } || conditions is { Length: > 300 } || notes is { Length: > 300 } || doctorName is { Length: > 60 }
            || doctorPhone is { Length: > 30 })
        {
            throw new DomainException("health.text_too_long", "Allergies, conditions and notes are at most 300, the doctor 60 and the phone 30 characters.");
        }

        BloodType = bloodType;
        Allergies = allergies;
        Conditions = conditions;
        DoctorName = doctorName;
        DoctorPhone = doctorPhone;
        Notes = notes;
        UpdatedAt = now;
    }

    internal static string? Clean(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();
}

/// <summary>
/// A vaccine the parents track: either planned (<see cref="DueOn"/>, from the doctor's card) or given (<see cref="GivenOn"/>).
/// Hally does not suggest a schedule.
/// </summary>
public class VaccineRecord : Entity
{
    private VaccineRecord() { }

    public VaccineRecord(Guid familyId, Guid childId, string name, DateOnly? dueOn, DateOnly? givenOn, string? note, Guid createdByUserId, DateOnly today,
        DateTimeOffset now)
    {
        FamilyId = familyId;
        ChildId = childId;
        CreatedByUserId = createdByUserId;
        CreatedAt = now;
        Update(name, dueOn, givenOn, note, today);
    }

    public Guid FamilyId { get; private set; }
    public Guid ChildId { get; private set; }
    public Guid? CreatedByUserId { get; private set; }
    public string Name { get; private set; } = default!;
    public DateOnly? DueOn { get; private set; }
    public DateOnly? GivenOn { get; private set; }
    public string? Note { get; private set; }

    public bool IsGiven => GivenOn is not null;

    public void Update(string name, DateOnly? dueOn, DateOnly? givenOn, string? note, DateOnly today)
    {
        if (string.IsNullOrWhiteSpace(name) || name.Trim().Length > 60)
        {
            throw new DomainException("vaccine.name_invalid", "Name must be 1-60 characters.");
        }

        if (dueOn is null && givenOn is null)
        {
            throw new DomainException("vaccine.date_required", "Give a due date or the date it was given.");
        }

        if (givenOn > today)
        {
            throw new DomainException("vaccine.given_in_future", "A vaccine cannot be given in the future.");
        }

        note = HealthProfile.Clean(note);
        if (note is { Length: > 200 })
        {
            throw new DomainException("vaccine.note_too_long", "Note is at most 200 characters.");
        }

        Name = name.Trim();
        DueOn = dueOn;
        GivenOn = givenOn;
        Note = note;
    }

    public void MarkGiven(DateOnly on, DateOnly today)
    {
        if (on > today)
        {
            throw new DomainException("vaccine.given_in_future", "A vaccine cannot be given in the future.");
        }

        GivenOn = on;
    }
}

/// <summary>Height, weight and head size on one day. At least one value; no percentiles or judgement.</summary>
public class GrowthMeasurement : Entity
{
    private GrowthMeasurement() { }

    public GrowthMeasurement(Guid familyId, Guid childId, DateOnly measuredOn, decimal? heightCm, decimal? weightKg, decimal? headCm,
        Guid createdByUserId, DateOnly today, DateTimeOffset now)
    {
        if (heightCm is null && weightKg is null && headCm is null)
        {
            throw new DomainException("growth.empty", "Enter a height, weight or head size.");
        }

        if (heightCm is < 30 or > 220 || weightKg is < 0.5m or > 200 || headCm is < 20 or > 70)
        {
            throw new DomainException("growth.out_of_range", "Height 30-220 cm, weight 0.5-200 kg, head 20-70 cm.");
        }

        if (measuredOn > today)
        {
            throw new DomainException("growth.in_future", "A measurement cannot be in the future.");
        }

        FamilyId = familyId;
        ChildId = childId;
        MeasuredOn = measuredOn;
        HeightCm = heightCm is null ? null : decimal.Round(heightCm.Value, 1);
        WeightKg = weightKg is null ? null : decimal.Round(weightKg.Value, 2);
        HeadCm = headCm is null ? null : decimal.Round(headCm.Value, 1);
        CreatedByUserId = createdByUserId;
        CreatedAt = now;
    }

    public Guid FamilyId { get; private set; }
    public Guid ChildId { get; private set; }
    public DateOnly MeasuredOn { get; private set; }
    public decimal? HeightCm { get; private set; }
    public decimal? WeightKg { get; private set; }
    public decimal? HeadCm { get; private set; }
    public Guid? CreatedByUserId { get; private set; }
}

/// <summary>
/// A doctor's appointment for a child. The time lives on an ordinary calendar event (so it shows on the calendar and gets the
/// usual reminders); this row only marks the event as a health appointment and keeps the doctor's name.
/// </summary>
public class HealthAppointment : Entity
{
    private HealthAppointment() { }

    public HealthAppointment(Guid familyId, Guid childId, Guid eventId, string? doctor, DateTimeOffset now)
    {
        doctor = HealthProfile.Clean(doctor);
        if (doctor is { Length: > 60 })
        {
            throw new DomainException("appointment.doctor_too_long", "Doctor is at most 60 characters.");
        }

        FamilyId = familyId;
        ChildId = childId;
        EventId = eventId;
        Doctor = doctor;
        CreatedAt = now;
    }

    public Guid FamilyId { get; private set; }
    public Guid ChildId { get; private set; }
    public Guid EventId { get; private set; }
    public string? Doctor { get; private set; }
}
