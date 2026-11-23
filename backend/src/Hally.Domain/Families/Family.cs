using Hally.Domain.Common;

namespace Hally.Domain.Families;

public class Family : Entity
{
    public const int MaxAdults = 6;

    private readonly List<FamilyMember> _members = [];
    private readonly List<Child> _children = [];

    private Family() { }

    public Family(string name, string timeZoneId, Guid ownerUserId)
    {
        Rename(name);
        SetTimeZone(timeZoneId);
        _members.Add(new FamilyMember(Id, ownerUserId, FamilyRole.Owner));
    }

    public string Name { get; private set; } = default!;
    public string TimeZoneId { get; private set; } = FamilyTimeZone.Default;
    public IReadOnlyCollection<FamilyMember> Members => _members;
    public IReadOnlyCollection<Child> Children => _children;

    public void Rename(string name)
    {
        if (string.IsNullOrWhiteSpace(name) || name.Trim().Length > 80)
        {
            throw new DomainException("family.name_invalid", "Family name must be 1-80 characters.");
        }

        Name = name.Trim();
    }

    public void SetTimeZone(string timeZoneId)
    {
        if (!FamilyTimeZone.IsValid(timeZoneId))
        {
            throw new DomainException("family.timezone_invalid", $"Unknown IANA time zone '{timeZoneId}'.");
        }

        TimeZoneId = timeZoneId;
    }

    public bool IsMember(Guid userId) => _members.Any(m => m.UserId == userId);

    public FamilyMember AddAdult(Guid userId)
    {
        var existing = _members.FirstOrDefault(m => m.UserId == userId);
        if (existing is not null)
        {
            return existing;
        }

        if (_members.Count >= MaxAdults)
        {
            throw new DomainException("family.adult_limit", $"A family can have at most {MaxAdults} adults.");
        }

        var member = new FamilyMember(Id, userId, FamilyRole.Adult);
        _members.Add(member);
        return member;
    }

    /// <summary>Removes an adult (leaving or deleting their account). If the owner leaves, the longest-standing
    /// remaining adult becomes owner. Returns false when the user was not a member.</summary>
    public bool RemoveMember(Guid userId)
    {
        var member = _members.FirstOrDefault(m => m.UserId == userId);
        if (member is null)
        {
            return false;
        }

        _members.Remove(member);
        if (member.Role == FamilyRole.Owner && _members.Count > 0 && _members.All(m => m.Role != FamilyRole.Owner))
        {
            _members.OrderBy(m => m.CreatedAt).First().Promote();
        }

        return true;
    }

    public const int MaxChildren = 10;

    /// <summary>Adds a child. Without a colour, the first palette colour no sibling uses yet is picked.</summary>
    public Child AddChild(string firstName, int? birthYear, string? color = null)
    {
        if (_children.Count >= MaxChildren)
        {
            throw new DomainException("family.child_limit", $"A family can have at most {MaxChildren} children.");
        }

        var used = _children.Select(c => c.Color).ToHashSet();
        var child = new Child(Id, firstName, birthYear,
            color ?? ChildColors.All.FirstOrDefault(c => !used.Contains(c)) ?? ChildColors.All[_children.Count % ChildColors.All.Count]);
        _children.Add(child);
        return child;
    }

    public bool RemoveChild(Guid childId) => _children.RemoveAll(c => c.Id == childId) > 0;
}

public enum FamilyRole
{
    Owner = 1,
    Adult = 2,
}

public class FamilyMember : Entity
{
    private FamilyMember() { }

    internal FamilyMember(Guid familyId, Guid userId, FamilyRole role)
    {
        FamilyId = familyId;
        UserId = userId;
        Role = role;
    }

    public Guid FamilyId { get; private set; }
    public Guid UserId { get; private set; }
    public FamilyRole Role { get; private set; }

    internal void Promote() => Role = FamilyRole.Owner;
}

/// <summary>A child profile. Only a first name is kept (no surname) to minimise PII.</summary>
public class Child : Entity
{
    private Child() { }

    internal Child(Guid familyId, string firstName, int? birthYear, string color)
    {
        FamilyId = familyId;
        Update(firstName, birthYear, color);
    }

    public Guid FamilyId { get; private set; }
    public string FirstName { get; private set; } = default!;
    public int? BirthYear { get; private set; }

    /// <summary>A key from <see cref="ChildColors.All"/>; the app maps it to a colour.</summary>
    public string Color { get; private set; } = ChildColors.All[0];

    /// <summary>Daily screen time goal in minutes (family-local day), or null for no goal.</summary>
    public int? DailyScreenMinutes { get; private set; }

    /// <summary>Storage key of the encrypted profile photo, or null when the child has none.</summary>
    public string? PhotoKey { get; private set; }
    public string? PhotoContentType { get; private set; }

    /// <summary>When the photo last changed; part of the photo URL so apps fetch a new one after a change.</summary>
    public DateTimeOffset? PhotoUpdatedAt { get; private set; }

    /// <summary>Sets the profile photo and returns the key of the one it replaces (to delete), if any.</summary>
    public string? SetPhoto(string key, string contentType, DateTimeOffset now)
    {
        var old = PhotoKey;
        PhotoKey = key;
        PhotoContentType = contentType;
        PhotoUpdatedAt = now;
        return old;
    }

    /// <summary>Removes the profile photo and returns its key (to delete), if there was one.</summary>
    public string? RemovePhoto()
    {
        var old = PhotoKey;
        PhotoKey = null;
        PhotoContentType = null;
        PhotoUpdatedAt = null;
        return old;
    }

    public const int MinScreenGoal = 5;
    public const int MaxScreenGoal = 24 * 60;

    /// <summary>Daily homework + reading minimum in minutes, or null for no goal.</summary>
    public int? DailyStudyMinutes { get; private set; }

    public const int MinStudyGoal = 5;
    public const int MaxStudyGoal = 4 * 60;

    public void SetStudyGoal(int? minutes)
    {
        if (minutes is { } m && (m < MinStudyGoal || m > MaxStudyGoal))
        {
            throw new DomainException("child.study_goal_invalid", $"Daily goal must be {MinStudyGoal}-{MaxStudyGoal} minutes.");
        }

        DailyStudyMinutes = minutes;
    }

    public void SetScreenTimeGoal(int? minutes)
    {
        if (minutes is { } m && (m < MinScreenGoal || m > MaxScreenGoal))
        {
            throw new DomainException("child.screen_goal_invalid", $"Daily goal must be {MinScreenGoal}-{MaxScreenGoal} minutes.");
        }

        DailyScreenMinutes = minutes;
    }

    public void Update(string firstName, int? birthYear, string color)
    {
        if (string.IsNullOrWhiteSpace(firstName) || firstName.Trim().Length > 40)
        {
            throw new DomainException("child.name_invalid", "Child first name must be 1-40 characters.");
        }

        if (birthYear is { } y && (y < DateTime.UtcNow.Year - 25 || y > DateTime.UtcNow.Year))
        {
            throw new DomainException("child.birth_year_invalid", "Birth year is out of range.");
        }

        if (!ChildColors.IsValid(color))
        {
            throw new DomainException("child.color_invalid", $"Color must be one of: {string.Join(", ", ChildColors.All)}.");
        }

        FirstName = firstName.Trim();
        BirthYear = birthYear;
        Color = color;
    }
}

/// <summary>Colour keys for children. Red and orange are left out on purpose: red is the brand colour and
/// orange marks delays, so neither may be mistaken for a child.</summary>
public static class ChildColors
{
    public static readonly IReadOnlyList<string> All = ["sky", "mint", "lavender", "sun", "teal", "indigo"];

    public static bool IsValid(string? color) => color is not null && All.Contains(color);
}
