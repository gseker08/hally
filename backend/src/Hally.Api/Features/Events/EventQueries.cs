using Hally.Domain.Planning;
using Hally.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.Events;

public static class EventQueries
{
    /// <summary>
    /// Event occurrences overlapping [start, end), ordered by start. Repeating events are expanded in the family's
    /// time zone; each occurrence keeps the series id.
    /// </summary>
    public static async Task<List<CalendarEvent>> EventsInRangeAsync(this HallyDbContext db, Guid familyId, DateTimeOffset start,
        DateTimeOffset end, string timeZoneId, CancellationToken ct)
    {
        // One-offs: a slightly wider window, then the exact overlap rule (with default durations) in memory.
        // Series: anything that started before the window ends and has not ended (by local date, with slack) before it.
        // PostgreSQL timestamptz parameters must be UTC; query strings like ?from=...+03:00 arrive with an offset.
        start = start.ToUniversalTime();
        end = end.ToUniversalTime();
        var windowStart = start.AddDays(-2);
        var untilFloor = DateOnly.FromDateTime(windowStart.UtcDateTime);
        var candidates = await db.Events.AsNoTracking()
            .Where(e => e.FamilyId == familyId && e.StartsAt < end
                        && (e.StartsAt >= windowStart
                            || (e.Repeat != EventRepeat.None && (e.RepeatUntil == null || e.RepeatUntil >= untilFloor))))
            .ToListAsync(ct);

        var zone = TimeZoneInfo.FindSystemTimeZoneById(timeZoneId);
        return candidates.SelectMany(e => e.OccurrencesOverlapping(start, end, zone))
            .OrderBy(e => e.StartsAt).ThenBy(e => e.Title, StringComparer.Ordinal).ToList();
    }

    public static Task<string> FamilyTimeZoneAsync(this HallyDbContext db, Guid familyId, CancellationToken ct) =>
        db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.TimeZoneId).FirstAsync(ct);
}
