using Hally.Domain.Families;
using Hally.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.Privacy;

/// <summary>Removes caregivers whose access end date passed, the same way as leaving the family (their direct chats,
/// reminders and notifications go). Until this runs, the end date already blocks every request.</summary>
public class CaregiverExpiryJob(HallyDbContext db, AccountService accounts, TimeProvider clock, ILogger<CaregiverExpiryJob> logger)
{
    public async Task<int> RunAsync(CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        var expired = await db.FamilyMembers.AsNoTracking()
            .Where(m => m.Role == FamilyRole.Caregiver && m.AccessUntil != null && m.AccessUntil <= now)
            .Select(m => new { m.UserId, m.FamilyId }).Take(200).ToListAsync(ct);
        foreach (var m in expired)
        {
            await accounts.LeaveFamilyAsync(m.UserId, m.FamilyId, ct);
        }

        if (expired.Count > 0)
        {
            logger.LogInformation("Removed {Count} caregivers whose access ended", expired.Count);
        }

        return expired.Count;
    }
}
