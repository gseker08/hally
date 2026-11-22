using Hally.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.Families;

public static class ChildQueries
{
    /// <summary>True when every id is a child of the family (an empty list is fine: it means the whole family).</summary>
    public static async Task<bool> AllChildrenInFamilyAsync(this HallyDbContext db, Guid familyId, IReadOnlyCollection<Guid> childIds, CancellationToken ct)
    {
        if (childIds.Count == 0)
        {
            return true;
        }

        var distinct = childIds.Distinct().ToList();
        return await db.Children.CountAsync(c => c.FamilyId == familyId && distinct.Contains(c.Id), ct) == distinct.Count;
    }
}
