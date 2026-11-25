using Hally.Domain.Common;

namespace Hally.Domain.Families;

/// <summary>An invitation for another parent or a caregiver to join a family. Only the token hash is stored.</summary>
public class Invitation : Entity
{
    public static readonly TimeSpan DefaultLifetime = TimeSpan.FromDays(7);

    private Invitation() { }

    public Invitation(Guid familyId, Guid invitedByUserId, string tokenHash, DateTimeOffset now, TimeSpan? lifetime = null,
        FamilyRole role = FamilyRole.Adult)
    {
        if (role is not (FamilyRole.Adult or FamilyRole.Caregiver))
        {
            throw new DomainException("invitation.role_invalid", "Invite a parent or a caregiver.");
        }

        Role = role;
        FamilyId = familyId;
        InvitedByUserId = invitedByUserId;
        TokenHash = tokenHash;
        CreatedAt = now;
        ExpiresAt = now + (lifetime ?? DefaultLifetime);
    }

    public Guid FamilyId { get; private set; }
    public Family? Family { get; private set; }
    public Guid InvitedByUserId { get; private set; }

    /// <summary>The role the invited person gets: <see cref="FamilyRole.Adult"/> (parent) or <see cref="FamilyRole.Caregiver"/>.</summary>
    public FamilyRole Role { get; private set; } = FamilyRole.Adult;

    /// <summary>Caregiver invitations: the access the caregiver gets on joining.</summary>
    public DateTimeOffset? AccessUntil { get; private set; }

    public List<Guid> ChildIds { get; private set; } = [];
    public bool CanSeeHealth { get; private set; }

    public CaregiverAccess Access => new(AccessUntil, ChildIds, CanSeeHealth);

    public void LimitCaregiver(CaregiverAccess access)
    {
        if (Role != FamilyRole.Caregiver)
        {
            throw new DomainException("invitation.not_caregiver", "Only a caregiver invitation carries access limits.");
        }

        AccessUntil = access.Until;
        ChildIds = access.ChildIds.Distinct().ToList();
        CanSeeHealth = access.CanSeeHealth;
    }
    public string TokenHash { get; private set; } = default!;
    public DateTimeOffset ExpiresAt { get; private set; }
    public Guid? AcceptedByUserId { get; private set; }
    public DateTimeOffset? AcceptedAt { get; private set; }
    public DateTimeOffset? RevokedAt { get; private set; }

    public InvitationStatus StatusAt(DateTimeOffset now) => this switch
    {
        { RevokedAt: not null } => InvitationStatus.Revoked,
        { AcceptedAt: not null } => InvitationStatus.Accepted,
        _ when ExpiresAt <= now => InvitationStatus.Expired,
        _ => InvitationStatus.Pending,
    };

    public void Accept(Family family, Guid userId, DateTimeOffset now)
    {
        if (family.Id != FamilyId)
        {
            throw new InvalidOperationException("Family does not match invitation.");
        }

        if (family.IsMember(userId))
        {
            return; // already in the family: accepting again is a no-op
        }

        var status = StatusAt(now);
        if (status != InvitationStatus.Pending)
        {
            throw new DomainException($"invitation.{status.ToString().ToLowerInvariant()}", $"Invitation is {status}.");
        }

        var member = family.AddMember(userId, Role);
        if (Role == FamilyRole.Caregiver)
        {
            // Children removed since the invitation was sent are dropped; an end date that already passed still applies.
            member.SetCaregiverAccess(Access with { ChildIds = ChildIds.Where(id => family.Children.Any(c => c.Id == id)).ToList() });
        }

        AcceptedByUserId = userId;
        AcceptedAt = now;
    }

    public void Revoke(DateTimeOffset now) => RevokedAt ??= now;
}

public enum InvitationStatus
{
    Pending,
    Accepted,
    Expired,
    Revoked,
}
