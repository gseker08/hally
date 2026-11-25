using FluentValidation;
using Hally.Api.Auth;
using Hally.Api.Common;
using Hally.Api.Features.Messages;
using Hally.Domain.Common;
using Hally.Domain.Feeding;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.Feeding;

public record FeedingEntryDto(Guid Id, Guid ChildId, string Kind, DateTimeOffset At, string? Side, int? Minutes, int? AmountMl, string? Food,
    string? Note, string? ByName);

/// <param name="Last">The latest feed of any kind.</param>
/// <param name="NextSide">The breast side to offer next (after Left comes Right); null when unknown.</param>
public record ChildFeedingStatusDto(Guid ChildId, FeedingEntryDto? Last, string? NextSide, int FeedsToday, int BottleMlToday);

/// <summary>Family-local calendar day totals.</summary>
public record FeedingDayDto(DateOnly Date, int Feeds, int BreastFeeds, int BreastMinutes, int Bottles, int BottleMl, int Solids);

public record ChildFeedingHistoryDto(Guid ChildId, IReadOnlyList<FeedingDayDto> Days, IReadOnlyList<FeedingEntryDto> Entries);

/// <param name="At">Defaults to now.</param>
public record AddFeedingRequest(FeedingKind Kind, DateTimeOffset? At = null, BreastSide? Side = null, int? Minutes = null, int? AmountMl = null,
    string? Food = null, string? Note = null);

/// <summary>Live note that a child's feeds changed; apps reload.</summary>
public record FeedingEvent(Guid FamilyId, Guid ChildId);

public class AddFeedingRequestValidator : AbstractValidator<AddFeedingRequest>
{
    public AddFeedingRequestValidator()
    {
        RuleFor(x => x.Minutes).InclusiveBetween(1, 120).When(x => x.Minutes.HasValue);
        RuleFor(x => x.AmountMl).InclusiveBetween(5, 500).When(x => x.AmountMl.HasValue);
        RuleFor(x => x.Food).MaximumLength(80);
        RuleFor(x => x.Note).MaximumLength(200);
    }
}

/// <summary>
/// Feeding log per child: breast (side, minutes), bottle (ml) and solid food, by either parent, shared live over
/// <c>/hubs/chat</c> (<c>FeedingChanged</c>). Answers "when did she last eat, and which side is next?".
/// </summary>
[ApiController]
[Authorize(Policy = Policies.FamilyMember)]
[CaregiverAllowed]
[Route("api/v1/families/{familyId:guid}")]
public class FeedingController(HallyDbContext db, IHubContext<ChatHub, IChatClient> hub, TimeProvider clock, ILogger<FeedingController> logger) : ControllerBase
{
    [HttpGet("feeding")]
    public async Task<IReadOnlyList<ChildFeedingStatusDto>> Status(Guid familyId, CancellationToken ct)
    {
        var tz = await TimeZone(familyId, ct);
        var children = await db.Children.AsNoTracking().Where(c => c.FamilyId == familyId).OrderBy(c => c.CreatedAt).Select(c => c.Id).ToListAsync(ct);
        var result = new List<ChildFeedingStatusDto>();
        foreach (var childId in children.Where(HttpContext.Access().SeesChild))
        {
            result.Add(await StatusAsync(childId, tz, ct));
        }

        return result;
    }

    /// <summary>The last <paramref name="days"/> family-local days, oldest first, and their feeds, newest first.</summary>
    [HttpGet("children/{childId:guid}/feeding")]
    public async Task<ChildFeedingHistoryDto> History(Guid familyId, Guid childId, [FromQuery] int days = 3, CancellationToken ct = default)
    {
        await EnsureChild(familyId, childId, ct);
        days = Math.Clamp(days, 1, 14);
        var tz = await TimeZone(familyId, ct);
        var today = FamilyTimeZone.LocalDate(clock.GetUtcNow(), tz);
        var first = today.AddDays(-(days - 1));
        var from = FamilyTimeZone.StartOfDay(first, tz);
        var entries = await db.FeedingEntries.AsNoTracking().Where(e => e.ChildId == childId && e.At >= from).OrderByDescending(e => e.At).ToListAsync(ct);
        var names = await Names(entries, ct);
        var dayList = Enumerable.Range(0, days).Select(i => first.AddDays(i)).Select(d =>
        {
            var on = entries.Where(e => FamilyTimeZone.LocalDate(e.At, tz) == d).ToList();
            var breast = on.Where(e => e.Kind == FeedingKind.Breast).ToList();
            var bottle = on.Where(e => e.Kind == FeedingKind.Bottle).ToList();
            return new FeedingDayDto(d, on.Count, breast.Count, breast.Sum(e => e.Minutes ?? 0), bottle.Count, bottle.Sum(e => e.AmountMl ?? 0),
                on.Count(e => e.Kind == FeedingKind.Solid));
        }).ToList();
        return new ChildFeedingHistoryDto(childId, dayList, entries.Select(e => Dto(e, names)).ToList());
    }

    [HttpPost("children/{childId:guid}/feeding")]
    [ProducesResponseType<ChildFeedingStatusDto>(201)]
    public async Task<IActionResult> Add(Guid familyId, Guid childId, AddFeedingRequest request, CancellationToken ct)
    {
        await EnsureChild(familyId, childId, ct);
        var now = clock.GetUtcNow();
        db.FeedingEntries.Add(new FeedingEntry(familyId, childId, User.UserId(), request.Kind, request.At ?? now, request.Side, request.Minutes,
            request.AmountMl, request.Food, request.Note, now));
        await db.SaveChangesAsync(ct);
        return StatusCode(201, await Changed(familyId, childId, ct));
    }

    [HttpDelete("children/{childId:guid}/feeding/{entryId:guid}")]
    public async Task<ChildFeedingStatusDto> Delete(Guid familyId, Guid childId, Guid entryId, CancellationToken ct)
    {
        var entry = await db.FeedingEntries.FirstOrDefaultAsync(e => e.Id == entryId && e.ChildId == childId && e.FamilyId == familyId, ct)
                    ?? throw new NotFoundException("feeding.not_found", "Feed not found.");
        db.FeedingEntries.Remove(entry);
        await db.SaveChangesAsync(ct);
        return await Changed(familyId, childId, ct);
    }

    private async Task<ChildFeedingStatusDto> StatusAsync(Guid childId, string tz, CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        var dayStart = FamilyTimeZone.StartOfDay(FamilyTimeZone.LocalDate(now, tz), tz);
        var last = await db.FeedingEntries.AsNoTracking().Where(e => e.ChildId == childId && e.At <= now).OrderByDescending(e => e.At).FirstOrDefaultAsync(ct);
        var lastBreast = await db.FeedingEntries.AsNoTracking().Where(e => e.ChildId == childId && e.Kind == FeedingKind.Breast && e.At <= now)
            .OrderByDescending(e => e.At).Select(e => e.Side).FirstOrDefaultAsync(ct);
        var today = await db.FeedingEntries.AsNoTracking().Where(e => e.ChildId == childId && e.At >= dayStart && e.At <= now).ToListAsync(ct);
        var names = await Names(last is null ? [] : [last], ct);
        return new ChildFeedingStatusDto(childId, last is null ? null : Dto(last, names), FeedingEntry.NextSide(lastBreast)?.ToString(),
            today.Count, today.Sum(e => e.AmountMl ?? 0));
    }

    private async Task<ChildFeedingStatusDto> Changed(Guid familyId, Guid childId, CancellationToken ct)
    {
        try
        {
            var adults = await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == familyId).Select(m => m.UserId).ToListAsync(ct);
            await hub.Clients.Groups(adults.Select(ChatHub.UserGroup).ToList()).FeedingChanged(new FeedingEvent(familyId, childId));
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Realtime feeding event failed");
        }

        return await StatusAsync(childId, await TimeZone(familyId, ct), ct);
    }

    private Task<string> TimeZone(Guid familyId, CancellationToken ct) =>
        db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.TimeZoneId).FirstAsync(ct);

    private async Task<Dictionary<Guid, string>> Names(IEnumerable<FeedingEntry> entries, CancellationToken ct)
    {
        var ids = entries.Select(e => e.ByUserId).OfType<Guid>().Distinct().ToList();
        return await db.Users.AsNoTracking().Where(u => ids.Contains(u.Id)).ToDictionaryAsync(u => u.Id, u => u.DisplayName, ct);
    }

    private static FeedingEntryDto Dto(FeedingEntry e, Dictionary<Guid, string> names) =>
        new(e.Id, e.ChildId, e.Kind.ToString(), e.At, e.Side?.ToString(), e.Minutes, e.AmountMl, e.Food, e.Note,
            e.ByUserId is { } u ? names.GetValueOrDefault(u) : null);

    private async Task EnsureChild(Guid familyId, Guid childId, CancellationToken ct)
    {
        if (!await db.Children.AnyAsync(c => c.FamilyId == familyId && c.Id == childId, ct))
        {
            throw new NotFoundException("child.not_found", "Child not found.");
        }
    }
}
