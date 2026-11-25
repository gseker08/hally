using Hally.Api.Common;
using Hally.Domain.Families;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Auth;

public static class Policies
{
    /// <summary>Caller must be a member of the family named by the {familyId} route value. Caregivers only pass on
    /// endpoints marked with <see cref="CaregiverAllowedAttribute"/>.</summary>
    public const string FamilyMember = "family-member";
}

public class FamilyMemberRequirement : IAuthorizationRequirement;

/// <summary>Lets caregivers use this endpoint (or every endpoint of this controller). Everything else in a family is
/// for parents only, so a new feature is closed to caregivers until someone decides otherwise.</summary>
[AttributeUsage(AttributeTargets.Class | AttributeTargets.Method)]
public sealed class CaregiverAllowedAttribute : Attribute
{
    /// <summary>Only caregivers a parent allowed to see health data (<see cref="FamilyMember.CanSeeHealth"/>).</summary>
    public bool Health { get; init; }
}

/// <summary>What the caller may see in the route's family, set once membership was checked.</summary>
public record FamilyAccessInfo(FamilyRole Role, IReadOnlySet<Guid>? ChildScope, bool CanSeeHealth)
{
    public bool IsParent => Role is FamilyRole.Owner or FamilyRole.Adult;

    /// <summary>A caregiver with a child list sees only those children; everyone else sees all.</summary>
    public bool SeesChild(Guid childId) => ChildScope is null || ChildScope.Contains(childId);

    /// <summary>Items tagged with children (tasks, events). Untagged items belong to the whole family and stay visible.</summary>
    public bool SeesTagged(IReadOnlyCollection<Guid> childIds) => ChildScope is null || childIds.Count == 0 || childIds.Any(ChildScope.Contains);
}

public static class FamilyAccess
{
    private const string Key = "hally.family-access";
    private static readonly FamilyAccessInfo None = new(Domain.Families.FamilyRole.Caregiver, new HashSet<Guid>(), false);

    public static FamilyAccessInfo Access(this HttpContext ctx) =>
        ctx.Items.TryGetValue(Key, out var a) && a is FamilyAccessInfo info ? info : None;

    public static bool IsParent(this HttpContext ctx) => ctx.Access().IsParent;

    internal static void SetAccess(this HttpContext ctx, FamilyAccessInfo access) => ctx.Items[Key] = access;
}

/// <summary>Enforces family isolation (every family-scoped route is checked against membership) and keeps
/// caregivers to the endpoints, children and time window a parent gave them.</summary>
public class FamilyMemberHandler(HallyDbContext db, IHttpContextAccessor http, TimeProvider clock) : AuthorizationHandler<FamilyMemberRequirement>
{
    protected override async Task HandleRequirementAsync(AuthorizationHandlerContext context, FamilyMemberRequirement requirement)
    {
        if (context.User.Identity?.IsAuthenticated != true || http.HttpContext is not { } ctx)
        {
            return;
        }

        if (!Guid.TryParse(ctx.GetRouteValue("familyId")?.ToString(), out var familyId))
        {
            return;
        }

        var userId = context.User.UserId();
        var member = await db.FamilyMembers.AsNoTracking().FirstOrDefaultAsync(m => m.FamilyId == familyId && m.UserId == userId, ctx.RequestAborted);
        if (member is null)
        {
            return;
        }

        if (member.Role == FamilyRole.Caregiver)
        {
            var allowed = ctx.GetEndpoint()?.Metadata.GetMetadata<CaregiverAllowedAttribute>();
            var childScope = member.ChildIds.Count == 0 ? null : member.ChildIds.ToHashSet();
            var outOfScope = childScope is not null && Guid.TryParse(ctx.GetRouteValue("childId")?.ToString(), out var childId) && !childScope.Contains(childId);
            if (allowed is null || !member.HasAccess(clock.GetUtcNow()) || (allowed.Health && !member.CanSeeHealth) || outOfScope)
            {
                context.Fail(new AuthorizationFailureReason(this, "Not available to this caregiver."));
                return;
            }

            ctx.SetAccess(new FamilyAccessInfo(member.Role, childScope, member.CanSeeHealth));
        }
        else
        {
            ctx.SetAccess(new FamilyAccessInfo(member.Role, null, true));
        }

        context.Succeed(requirement);
    }
}
