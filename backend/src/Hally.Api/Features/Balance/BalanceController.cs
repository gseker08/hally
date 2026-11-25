using Hally.Api.Auth;
using Hally.Domain.Common;
using Hally.Domain.Duties;
using Hally.Domain.Families;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.Balance;

/// <summary>What one adult did in the range. <c>Role</c> is "Parent" or "Caregiver".</summary>
public record BalanceMemberDto(
    Guid UserId,
    string Name,
    string Role,
    int Tasks,
    int SchoolRuns,
    int Feedings,
    int Shopping,
    int Medications,
    int Total);

/// <summary>
/// A gentle nudge when one parent carries more than <see cref="BalanceController.HeavyShare"/> of the work: the next
/// school run planned for them in the coming week (if any) could go to the parent who did least. The app only opens a
/// pre-written chat message; nothing changes until the parents agree.
/// </summary>
public record BalanceSuggestionDto(Guid HeavyUserId, string HeavyName, int SharePercent, Guid ToUserId, string ToName, DateOnly? Date, string? Kind);

public record BalanceDto(DateOnly From, DateOnly To, DateOnly Today, int Total, IReadOnlyList<BalanceMemberDto> Members, BalanceSuggestionDto? Suggestion);

/// <summary>
/// "Bu hafta kim ne yaptı?": per adult, how many tasks they completed, school runs they marked done, feeds they logged,
/// shopping items they ticked and medicine doses they gave. Counts only what was marked in Hally, so it is a conversation
/// starter, not a scoreboard. Parents only (caregivers appear in it but cannot open it).
/// </summary>
[ApiController]
[Authorize(Policy = Policies.FamilyMember)]
[Route("api/v1/families/{familyId:guid}/balance")]
public class BalanceController(HallyDbContext db, TimeProvider clock) : ControllerBase
{
    public const int MaxDays = 31;

    /// <summary>Above this share of the family's total (and with enough to go on) a suggestion is offered.</summary>
    public const double HeavyShare = 0.40;

    private const int MinTotalForSuggestion = 6;

    /// <summary><c>from</c>/<c>to</c> are inclusive family-local days; default this week from Monday to today.</summary>
    [HttpGet]
    public async Task<BalanceDto> Get(Guid familyId, [FromQuery] DateOnly? from, [FromQuery] DateOnly? to, CancellationToken ct)
    {
        var tz = await db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.TimeZoneId).FirstAsync(ct);
        var today = FamilyTimeZone.LocalDate(clock.GetUtcNow(), tz);
        var last = to ?? today;
        var first = from ?? MondayOf(last);
        if (first > last || last.DayNumber - first.DayNumber + 1 > MaxDays)
        {
            throw new DomainException("balance.range_invalid", $"The range must be 1-{MaxDays} days.");
        }

        var start = FamilyTimeZone.StartOfDay(first, tz);
        var end = FamilyTimeZone.StartOfDay(last.AddDays(1), tz);

        var members = await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == familyId)
            .Join(db.Users.AsNoTracking(), m => m.UserId, u => u.Id, (m, u) => new { m.UserId, m.Role, u.DisplayName, m.CreatedAt })
            .OrderBy(m => m.CreatedAt).ToListAsync(ct);
        var ids = members.Select(m => m.UserId).ToList();

        var tasks = await db.Tasks.AsNoTracking()
            .Where(t => t.FamilyId == familyId && t.CompletedByUserId != null && t.CompletedAt >= start && t.CompletedAt < end)
            .GroupBy(t => t.CompletedByUserId!.Value).Select(g => new { g.Key, Count = g.Count() }).ToDictionaryAsync(g => g.Key, g => g.Count, ct);
        var runs = await db.DutyDones.AsNoTracking()
            .Where(d => d.FamilyId == familyId && d.ByUserId != null && d.Date >= first && d.Date <= last)
            .GroupBy(d => d.ByUserId!.Value).Select(g => new { g.Key, Count = g.Count() }).ToDictionaryAsync(g => g.Key, g => g.Count, ct);
        var feeds = await db.FeedingEntries.AsNoTracking()
            .Where(f => f.FamilyId == familyId && f.ByUserId != null && f.At >= start && f.At < end)
            .GroupBy(f => f.ByUserId!.Value).Select(g => new { g.Key, Count = g.Count() }).ToDictionaryAsync(g => g.Key, g => g.Count, ct);
        var shopping = await db.ShoppingItems.AsNoTracking()
            .Where(s => s.FamilyId == familyId && s.CheckedByUserId != null && s.CheckedAt >= start && s.CheckedAt < end)
            .GroupBy(s => s.CheckedByUserId!.Value).Select(g => new { g.Key, Count = g.Count() }).ToDictionaryAsync(g => g.Key, g => g.Count, ct);
        var doses = await db.MedicationDoses.AsNoTracking()
            .Where(d => d.FamilyId == familyId && d.GivenByUserId != null && d.GivenAt >= start && d.GivenAt < end)
            .GroupBy(d => d.GivenByUserId!.Value).Select(g => new { g.Key, Count = g.Count() }).ToDictionaryAsync(g => g.Key, g => g.Count, ct);

        var rows = members.Select(m =>
        {
            int Of(Dictionary<Guid, int> d) => d.GetValueOrDefault(m.UserId);
            var (t, r, f, s, d) = (Of(tasks), Of(runs), Of(feeds), Of(shopping), Of(doses));
            return new BalanceMemberDto(m.UserId, m.DisplayName, m.Role == FamilyRole.Caregiver ? "Caregiver" : "Parent", t, r, f, s, d, t + r + f + s + d);
        }).ToList();
        var total = rows.Sum(r => r.Total);

        BalanceSuggestionDto? suggestion = null;
        var parents = rows.Where(r => r.Role == "Parent").ToList();
        var heavy = rows.OrderByDescending(r => r.Total).FirstOrDefault();
        if (last == today && parents.Count >= 2 && total >= MinTotalForSuggestion && heavy is { Role: "Parent" }
            && (double)heavy.Total / total > HeavyShare)
        {
            var light = parents.Where(p => p.UserId != heavy.UserId).OrderBy(p => p.Total).First();
            var (date, kind) = await NextRunFor(familyId, heavy.UserId, today, ct);
            suggestion = new BalanceSuggestionDto(heavy.UserId, heavy.Name, (int)Math.Round(100.0 * heavy.Total / total),
                light.UserId, light.Name, date, kind?.ToString());
        }

        return new BalanceDto(first, last, today, total, rows, suggestion);
    }

    /// <summary>The first school run planned for <paramref name="userId"/> from tomorrow through the next 7 days.</summary>
    private async Task<(DateOnly?, DutyKind?)> NextRunFor(Guid familyId, Guid userId, DateOnly today, CancellationToken ct)
    {
        var rules = await db.DutyRules.AsNoTracking().Where(r => r.FamilyId == familyId).ToListAsync(ct);
        var until = today.AddDays(7);
        var overrides = await db.DutyOverrides.AsNoTracking().Where(o => o.FamilyId == familyId && o.Date > today && o.Date <= until).ToListAsync(ct);
        for (var date = today.AddDays(1); date <= until; date = date.AddDays(1))
        {
            foreach (var kind in new[] { DutyKind.DropOff, DutyKind.PickUp })
            {
                DutyAssignment? plan = overrides.FirstOrDefault(o => o.Date == date && o.Kind == kind)
                                       ?? (DutyAssignment?)rules.FirstOrDefault(r => r.Weekday == Weekday(date) && r.Kind == kind);
                if (plan?.AssigneeUserId == userId)
                {
                    return (date, kind);
                }
            }
        }

        return (null, null);
    }

    private static int Weekday(DateOnly d) => ((int)d.DayOfWeek + 6) % 7;

    private static DateOnly MondayOf(DateOnly d) => d.AddDays(-Weekday(d));
}
