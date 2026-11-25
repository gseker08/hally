using Hally.Domain.Common;

namespace Hally.Domain.Families;

public class Family : Entity
{
    /// <summary>Parents (mother, father or another parent figure). Caregivers are counted separately.</summary>
    public const int MaxAdults = 6;

    public const int MaxCaregivers = 4;

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

    /// <summary>Child mode: a chore or habit the child marks done gives cherries only after a parent approves it.</summary>
    public bool RequireChildApproval { get; private set; } = true;

    public void SetChildApproval(bool required) => RequireChildApproval = required;

    /// <summary>The city whose weather picks screen-free ideas (indoors when it rains). Optional; only the city is
    /// stored, rounded to about 10 km, never a home address.</summary>
    public string? WeatherPlace { get; private set; }
    public double? WeatherLatitude { get; private set; }
    public double? WeatherLongitude { get; private set; }

    public void SetWeatherPlace(string? name, double? latitude, double? longitude)
    {
        if (string.IsNullOrWhiteSpace(name))
        {
            (WeatherPlace, WeatherLatitude, WeatherLongitude) = (null, null, null);
            return;
        }

        if (name.Trim().Length > 80 || latitude is not (>= -90 and <= 90) || longitude is not (>= -180 and <= 180))
        {
            throw new DomainException("family.weather_place_invalid", "Pick a city from the list.");
        }

        (WeatherPlace, WeatherLatitude, WeatherLongitude) = (name.Trim(), Math.Round(latitude.Value, 1), Math.Round(longitude.Value, 1));
    }
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

    public FamilyMember? MemberOf(Guid userId) => _members.FirstOrDefault(m => m.UserId == userId);

    /// <summary>True when no other parent would remain after this user leaves.</summary>
    public bool IsLastParent(Guid userId) => !_members.Any(m => m.IsParent && m.UserId != userId);

    public FamilyMember AddAdult(Guid userId) => AddMember(userId, FamilyRole.Adult);

    /// <summary>Adds a parent (<see cref="FamilyRole.Adult"/>) or a <see cref="FamilyRole.Caregiver"/>. A user who is
    /// already a member keeps their current role.</summary>
    public FamilyMember AddMember(Guid userId, FamilyRole role)
    {
        if (role == FamilyRole.Owner)
        {
            throw new ArgumentException("The owner is set when the family is created.", nameof(role));
        }

        var existing = _members.FirstOrDefault(m => m.UserId == userId);
        if (existing is not null)
        {
            return existing;
        }

        if (role == FamilyRole.Caregiver)
        {
            if (_members.Count(m => m.Role == FamilyRole.Caregiver) >= MaxCaregivers)
            {
                throw new DomainException("family.caregiver_limit", $"A family can have at most {MaxCaregivers} caregivers.");
            }
        }
        else if (_members.Count(m => m.IsParent) >= MaxAdults)
        {
            throw new DomainException("family.adult_limit", $"A family can have at most {MaxAdults} adults.");
        }

        var member = new FamilyMember(Id, userId, role);
        _members.Add(member);
        return member;
    }

    /// <summary>Removes a member (leaving or deleting their account). If the owner leaves, the longest-standing
    /// remaining parent becomes owner. Callers delete the whole family instead when the last parent leaves
    /// (see <see cref="IsLastParent"/>): a caregiver never keeps a family on their own. Returns false when the user was not a member.</summary>
    public bool RemoveMember(Guid userId)
    {
        var member = _members.FirstOrDefault(m => m.UserId == userId);
        if (member is null)
        {
            return false;
        }

        _members.Remove(member);
        if (member.Role == FamilyRole.Owner && _members.Any(m => m.IsParent) && _members.All(m => m.Role != FamilyRole.Owner))
        {
            _members.Where(m => m.IsParent).OrderBy(m => m.CreatedAt).First().Promote();
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

/// <summary>A member's role. <see cref="Owner"/> and <see cref="Adult"/> are both parents with equal rights (the owner
/// is only who created the family). A <see cref="Caregiver"/> (nanny, grandparent) helps with the day-to-day but
/// cannot manage the family, billing, expenses or health records.</summary>
public enum FamilyRole
{
    Owner = 1,
    Adult = 2,
    Caregiver = 3,
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

    public bool IsParent => Role is FamilyRole.Owner or FamilyRole.Adult;

    /// <summary>Caregivers only: when their access ends (null = until a parent removes them).</summary>
    public DateTimeOffset? AccessUntil { get; private set; }

    /// <summary>Caregivers only: the children they look after. Empty means every child in the family.</summary>
    public List<Guid> ChildIds { get; private set; } = [];

    /// <summary>Caregivers only: may read the health card (allergies, vaccines, growth). Health data is special-category
    /// personal data under KVKK, so this is off unless a parent turns it on.</summary>
    public bool CanSeeHealth { get; private set; }

    public bool HasAccess(DateTimeOffset now) => AccessUntil is not { } until || until > now;

    /// <summary>Sets what a caregiver can reach. Parents always see everything.</summary>
    public void SetCaregiverAccess(CaregiverAccess access)
    {
        if (Role != FamilyRole.Caregiver)
        {
            throw new DomainException("member.not_caregiver", "Only a caregiver's access can be limited.");
        }

        AccessUntil = access.Until;
        ChildIds = access.ChildIds.Distinct().ToList();
        CanSeeHealth = access.CanSeeHealth;
    }

    internal void Promote() => Role = FamilyRole.Owner;
}

/// <summary>What a caregiver can reach: until when, which children (empty = all), and whether the health card.</summary>
public record CaregiverAccess(DateTimeOffset? Until, IReadOnlyList<Guid> ChildIds, bool CanSeeHealth)
{
    public static readonly CaregiverAccess Default = new(null, [], false);

    public void Validate(Family family, DateTimeOffset now)
    {
        if (Until is { } until && until <= now)
        {
            throw new DomainException("caregiver.until_invalid", "Access must end in the future.");
        }

        if (ChildIds.Any(id => family.Children.All(c => c.Id != id)))
        {
            throw new DomainException("child.not_found", "Child not found.");
        }
    }
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
