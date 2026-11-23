using Hally.Domain.Common;

namespace Hally.Domain.Duties;

public enum DutyKind
{
    /// <summary>Taking the children to school.</summary>
    DropOff,

    /// <summary>Picking them up.</summary>
    PickUp,
}

/// <summary>Who does a duty: a family adult, or someone outside the app by name ("Babaanne", "Servis").</summary>
public abstract class DutyAssignment : Entity
{
    public Guid FamilyId { get; protected set; }
    public DutyKind Kind { get; protected set; }
    public Guid? AssigneeUserId { get; protected set; }
    public string? AssigneeName { get; protected set; }
    public TimeOnly? Time { get; protected set; }

    protected void Assign(Guid? userId, string? name, TimeOnly? time)
    {
        name = string.IsNullOrWhiteSpace(name) ? null : name.Trim();
        if (userId is not null && name is not null)
        {
            throw new DomainException("duty.assignee_invalid", "Pick a family adult or type a name, not both.");
        }

        if (name is { Length: > 40 })
        {
            throw new DomainException("duty.name_too_long", "Name can be up to 40 characters.");
        }

        AssigneeUserId = userId;
        AssigneeName = name;
        Time = time;
    }
}

/// <summary>The usual plan for a weekday ("Mondays Ayşe drops off at 08:15").</summary>
public class DutyRule : DutyAssignment
{
    private DutyRule() { }

    /// <param name="weekday">0 Monday … 6 Sunday.</param>
    public DutyRule(Guid familyId, int weekday, DutyKind kind, Guid? userId, string? name, TimeOnly? time, DateTimeOffset now)
    {
        if (weekday is < 0 or > 6)
        {
            throw new DomainException("duty.weekday_invalid", "Weekday must be 0 (Monday) to 6 (Sunday).");
        }

        FamilyId = familyId;
        Weekday = weekday;
        Kind = kind;
        CreatedAt = now;
        Update(userId, name, time);
    }

    public int Weekday { get; private set; }

    public void Update(Guid? userId, string? name, TimeOnly? time) => Assign(userId, name, time);
}

/// <summary>A change for one date ("Thursday Mehmet picks up instead"). No assignee means nobody is needed that day.</summary>
public class DutyOverride : DutyAssignment
{
    private DutyOverride() { }

    public DutyOverride(Guid familyId, DateOnly date, DutyKind kind, Guid? userId, string? name, TimeOnly? time, DateTimeOffset now)
    {
        FamilyId = familyId;
        Date = date;
        Kind = kind;
        CreatedAt = now;
        Update(userId, name, time);
    }

    public DateOnly Date { get; private set; }

    public void Update(Guid? userId, string? name, TimeOnly? time) => Assign(userId, name, time);
}

/// <summary>"Dropped off" / "Picked up" for a date, tapped by whoever did it.</summary>
public class DutyDone : Entity
{
    private DutyDone() { }

    public DutyDone(Guid familyId, DateOnly date, DutyKind kind, Guid userId, DateTimeOffset now)
    {
        FamilyId = familyId;
        Date = date;
        Kind = kind;
        ByUserId = userId;
        CreatedAt = now;
    }

    public Guid FamilyId { get; private set; }
    public DateOnly Date { get; private set; }
    public DutyKind Kind { get; private set; }
    public Guid? ByUserId { get; private set; }
}
