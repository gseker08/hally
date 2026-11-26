using Hally.Api.Auth;
using Hally.Api.Common;
using Hally.Domain.Families;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.Focus;

/// <param name="Areas">The chosen areas in order (see <see cref="FocusArea"/>); empty means Today shows everything.</param>
/// <param name="SetupDone">False until the member finishes or skips the setup wizard.</param>
public record FocusDto(IReadOnlyList<string> Areas, bool SetupDone);

public record SetFocusRequest(IReadOnlyList<string>? Areas);

/// <summary>
/// "Bugün ekranım": each parent's own choice of what Today puts first, set by the setup wizard and changeable in Profile.
/// Per member, so two parents in one family can choose differently.
/// </summary>
[ApiController]
[Authorize(Policy = Policies.FamilyMember)]
[Route("api/v1/families/{familyId:guid}/focus")]
public class FocusController(HallyDbContext db, TimeProvider clock) : ControllerBase
{
    [HttpGet]
    public async Task<FocusDto> Get(Guid familyId, CancellationToken ct)
    {
        var userId = User.UserId();
        var m = await db.FamilyMembers.AsNoTracking().FirstAsync(x => x.FamilyId == familyId && x.UserId == userId, ct);
        return new FocusDto(m.FocusAreas, m.SetupCompletedAt != null);
    }

    /// <summary>Saves the areas and marks setup done; an empty list is "skip" (everything stays on Today).</summary>
    [HttpPut]
    public async Task<FocusDto> Set(Guid familyId, SetFocusRequest request, CancellationToken ct)
    {
        var userId = User.UserId();
        var m = await db.FamilyMembers.FirstAsync(x => x.FamilyId == familyId && x.UserId == userId, ct);
        m.SetFocus(request.Areas ?? [], clock.GetUtcNow());
        await db.SaveChangesAsync(ct);
        return new FocusDto(m.FocusAreas, true);
    }
}
