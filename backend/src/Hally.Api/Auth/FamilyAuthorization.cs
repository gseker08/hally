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
public sealed class CaregiverAllowedAttribute : Attribute;

public static class FamilyAccess
{
    private const string RoleKey = "hally.family-role";

    /// <summary>The caller's role in the route's family, set once membership was checked.</summary>
    public static FamilyRole FamilyRole(this HttpContext ctx) =>
        ctx.Items.TryGetValue(RoleKey, out var role) && role is FamilyRole r ? r : Domain.Families.FamilyRole.Caregiver;

    public static bool IsParent(this HttpContext ctx) => ctx.FamilyRole() is Domain.Families.FamilyRole.Owner or Domain.Families.FamilyRole.Adult;

    internal static void SetFamilyRole(this HttpContext ctx, FamilyRole role) => ctx.Items[RoleKey] = role;
}

/// <summary>Enforces family isolation (every family-scoped route is checked against membership) and keeps
/// caregivers to the endpoints opened for them.</summary>
public class FamilyMemberHandler(HallyDbContext db, IHttpContextAccessor http) : AuthorizationHandler<FamilyMemberRequirement>
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
        var role = await db.FamilyMembers.Where(m => m.FamilyId == familyId && m.UserId == userId)
            .Select(m => (FamilyRole?)m.Role).FirstOrDefaultAsync(ctx.RequestAborted);
        if (role is not { } r)
        {
            return;
        }

        if (r == FamilyRole.Caregiver && ctx.GetEndpoint()?.Metadata.GetMetadata<CaregiverAllowedAttribute>() is null)
        {
            context.Fail(new AuthorizationFailureReason(this, "Parents only."));
            return;
        }

        ctx.SetFamilyRole(r);
        context.Succeed(requirement);
    }
}
