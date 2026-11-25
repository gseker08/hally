using Hally.Api.Auth;
using Hally.Api.Common;
using Hally.Api.Features.Messages;
using Hally.Api.Features.Notifications;
using Hally.Api.Features.Points;
using Hally.Api.Features.Proposals;
using Hally.Domain.Asks;
using Hally.Domain.ChildMode;
using Hally.Domain.Common;
using Hally.Domain.Families;
using Hally.Domain.Notifications;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.Asks;

/// <param name="Question">A follow-up with quick answers, e.g. "Kimin evine?".</param>
/// <param name="ScreenMinutes">A yes gives this many extra screen minutes.</param>
public record AskPresetDto(Guid? Id, string Emoji, string Title, string? Question, IReadOnlyList<string>? Options, int? ScreenMinutes);

/// <param name="Status">Pending, Yes, No or Expired (nobody answered that day).</param>
public record AskDto(
    Guid Id,
    Guid ChildId,
    string ChildName,
    string Emoji,
    string Title,
    string? Detail,
    int? ScreenMinutes,
    string Status,
    string? Note,
    string? AnsweredByName,
    DateTimeOffset? AnsweredAt,
    DateTimeOffset CreatedAt);

public record ChildAsksDto(IReadOnlyList<AskPresetDto> Presets, IReadOnlyList<AskDto> Asks);

/// <param name="PresetId">A ready-made request; or <paramref name="Text"/> for "Kendim yazayım…".</param>
/// <param name="Detail">The answer to the preset's follow-up question ("Zeynep").</param>
public record NewAskRequest(Guid? PresetId, string? Text, string? Detail);

public record AnswerAskRequest(bool Yes, string? Note);

public record AskPresetsRequest(IReadOnlyList<AskPresetDto> Presets);

public class AskService(HallyDbContext db, NotificationPublisher publisher, IHubContext<ChatHub, IChatClient> hub, TimeProvider clock, ILogger<AskService> logger)
{
    /// <summary>The family's ready-made requests, created from the defaults on first use.</summary>
    public async Task<IReadOnlyList<AskPreset>> PresetsAsync(Guid familyId, bool turkish, CancellationToken ct)
    {
        var presets = await db.AskPresets.AsNoTracking().Where(p => p.FamilyId == familyId).OrderBy(p => p.Order).ToListAsync(ct);
        if (presets.Count > 0 || await db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.AskPresetsEdited).FirstAsync(ct))
        {
            return presets;
        }

        var now = clock.GetUtcNow();
        presets = AskPreset.Defaults(turkish).Select((d, i) => new AskPreset(familyId, i, d.Emoji, d.Title, d.Question, d.Options, d.Minutes, now)).ToList();
        db.AskPresets.AddRange(presets);
        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (DbUpdateException)
        {
            // Two phones opened the page at once; the other one created the list.
            db.ChangeTracker.Clear();
            return await db.AskPresets.AsNoTracking().Where(p => p.FamilyId == familyId).OrderBy(p => p.Order).ToListAsync(ct);
        }

        return presets;
    }

    public async Task<IReadOnlyList<AskPreset>> SetPresetsAsync(Guid familyId, IReadOnlyList<AskPresetDto> items, CancellationToken ct)
    {
        if (items.Count > AskPreset.MaxPerFamily)
        {
            throw new DomainException("ask.presets_too_many", $"At most {AskPreset.MaxPerFamily} requests.");
        }

        var family = await db.Families.FirstAsync(f => f.Id == familyId, ct);
        var existing = await db.AskPresets.Where(p => p.FamilyId == familyId).ToListAsync(ct);
        var now = clock.GetUtcNow();

        // Orders are unique per family: park the kept ones out of the way first, then number the new list.
        var kept = items.Where(i => i.Id is { } id && existing.Any(e => e.Id == id)).Select(i => i.Id!.Value).ToHashSet();
        db.AskPresets.RemoveRange(existing.Where(e => !kept.Contains(e.Id)));
        foreach (var e in existing.Where(e => kept.Contains(e.Id)))
        {
            e.Update(1000 + e.Order, e.Emoji, e.Title, e.Question, e.Options, e.ScreenMinutes);
        }

        await db.SaveChangesAsync(ct);

        for (var i = 0; i < items.Count; i++)
        {
            var item = items[i];
            if (item.Id is { } id && existing.FirstOrDefault(e => e.Id == id) is { } preset && kept.Contains(id))
            {
                preset.Update(i, item.Emoji, item.Title, item.Question, item.Options ?? [], item.ScreenMinutes);
            }
            else
            {
                db.AskPresets.Add(new AskPreset(familyId, i, item.Emoji, item.Title, item.Question, item.Options ?? [], item.ScreenMinutes, now));
            }
        }

        family.MarkAskPresetsEdited();
        await db.SaveChangesAsync(ct);
        return await db.AskPresets.AsNoTracking().Where(p => p.FamilyId == familyId).OrderBy(p => p.Order).ToListAsync(ct);
    }

    /// <summary>The child asks. 422 <c>ask.already_pending</c> when the same request still waits, <c>ask.too_many</c>
    /// with <see cref="ChildAsk.MaxPending"/> open requests or <see cref="ChildAsk.MaxPerDay"/> today.</summary>
    public async Task<ChildAsk> AskAsync(Guid familyId, Guid childId, NewAskRequest request, CancellationToken ct)
    {
        var tz = await db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.TimeZoneId).FirstAsync(ct);
        var now = clock.GetUtcNow();
        var today = FamilyTimeZone.LocalDate(now, tz);

        ChildAsk ask;
        if (request.PresetId is { } presetId)
        {
            var preset = await db.AskPresets.AsNoTracking().FirstOrDefaultAsync(p => p.Id == presetId && p.FamilyId == familyId, ct)
                         ?? throw new NotFoundException("ask.preset_not_found", "Request not found.");
            ask = new ChildAsk(familyId, childId, preset.Id, preset.Emoji, preset.Title, request.Detail, preset.ScreenMinutes, today, now);
        }
        else
        {
            ask = new ChildAsk(familyId, childId, null, "💬", request.Text ?? "", null, null, today, now);
        }

        return await AddAsync(ask, ct);
    }

    /// <summary>"15 dk daha iste" on the lock screen: a request whose yes gives the minutes. Asking again while it
    /// waits does nothing.</summary>
    public async Task TimeAsync(Guid familyId, Guid childId, int minutes, CancellationToken ct)
    {
        var tz = await db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.TimeZoneId).FirstAsync(ct);
        var now = clock.GetUtcNow();
        var today = FamilyTimeZone.LocalDate(now, tz);
        if (await db.ChildAsks.AnyAsync(a => a.ChildId == childId && a.Day == today && a.Status == AskStatus.Pending && a.ScreenMinutes != null, ct))
        {
            return;
        }

        var turkish = await ParentsSpeakTurkishAsync(familyId, ct);
        var title = turkish ? $"{minutes} dk daha ekran" : $"{minutes} more minutes of screen time";
        try
        {
            await AddAsync(new ChildAsk(familyId, childId, null, "⏱️", title, null, minutes, today, now), ct);
        }
        catch (DomainException e) when (e.Code == "ask.too_many")
        {
            // The lock screen button stays quiet; the open requests are already with the parents.
        }
    }

    private async Task<ChildAsk> AddAsync(ChildAsk ask, CancellationToken ct)
    {
        var mine = await db.ChildAsks.AsNoTracking().Where(a => a.ChildId == ask.ChildId && a.Day == ask.Day).Select(a => new { a.Status, a.PresetId, a.Title }).ToListAsync(ct);
        if (mine.Any(a => a.Status == AskStatus.Pending && (ask.PresetId is { } p ? a.PresetId == p : a.Title == ask.Title)))
        {
            throw new DomainException("ask.already_pending", "This request is still waiting for an answer.");
        }

        if (mine.Count(a => a.Status == AskStatus.Pending) >= ChildAsk.MaxPending || mine.Count >= ChildAsk.MaxPerDay)
        {
            throw new DomainException("ask.too_many", "Wait for an answer before asking more.");
        }

        db.ChildAsks.Add(ask);
        await db.SaveChangesAsync(ct);
        await NotifyAsync(ask, ct);
        await AnnounceAsync(ask.FamilyId, ct);
        return ask;
    }

    /// <summary>The first answer counts: 409 <c>ask.already_answered</c> (naming who) when another parent was faster,
    /// 422 <c>ask.expired</c> for a request from an earlier day. A yes on a screen-time request adds the minutes.</summary>
    public async Task<AskDto> AnswerAsync(Guid familyId, Guid askId, Guid userId, AnswerAskRequest request, CancellationToken ct)
    {
        var note = ChildAsk.CleanNote(request.Note);
        var ask = await db.ChildAsks.AsNoTracking().FirstOrDefaultAsync(a => a.Id == askId && a.FamilyId == familyId, ct)
                  ?? throw new NotFoundException("ask.not_found", "Request not found.");
        var tz = await db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.TimeZoneId).FirstAsync(ct);
        var now = clock.GetUtcNow();
        var today = FamilyTimeZone.LocalDate(now, tz);
        if (ask.Status == AskStatus.Pending && ask.Day < today)
        {
            throw new DomainException("ask.expired", "This request is from an earlier day.");
        }

        var status = request.Yes ? AskStatus.Yes : AskStatus.No;
        var won = await db.ChildAsks.Where(a => a.Id == askId && a.Status == AskStatus.Pending)
            .ExecuteUpdateAsync(s => s.SetProperty(a => a.Status, status).SetProperty(a => a.AnsweredByUserId, userId)
                .SetProperty(a => a.AnsweredAt, now).SetProperty(a => a.Note, note), ct);
        if (won == 0)
        {
            var by = await NameOfAsync(askId, ct);
            throw new ConflictException("ask.already_answered", by is null ? "Already answered." : $"{by} already answered.");
        }

        if (request.Yes && ask.ScreenMinutes is { } minutes)
        {
            db.ScreenBonuses.Add(new ScreenBonus(familyId, ask.ChildId, today, minutes, BonusSource.Parent, userId, now));
            await db.SaveChangesAsync(ct);
        }

        await TellOtherParentsAsync(ask, userId, request.Yes, ct);
        await AnnounceAsync(familyId, ct);
        return (await ListAsync(familyId, null, [askId], ct)).Single();
    }

    /// <summary>Today's requests plus anything still open, newest first.</summary>
    public async Task<IReadOnlyList<AskDto>> ListAsync(Guid familyId, Guid? childId, IReadOnlyList<Guid>? ids, CancellationToken ct)
    {
        var tz = await db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.TimeZoneId).FirstAsync(ct);
        var today = FamilyTimeZone.LocalDate(clock.GetUtcNow(), tz);
        var query = db.ChildAsks.AsNoTracking().Where(a => a.FamilyId == familyId);
        query = ids is not null ? query.Where(a => ids.Contains(a.Id))
            : query.Where(a => a.Day == today || (a.Status == AskStatus.Pending && a.Day >= today.AddDays(-1)));
        if (childId is { } c)
        {
            query = query.Where(a => a.ChildId == c);
        }

        var rows = await query.OrderByDescending(a => a.CreatedAt).Take(50)
            .Join(db.Children.AsNoTracking(), a => a.ChildId, k => k.Id, (a, k) => new { a, k.FirstName })
            .GroupJoin(db.Users.AsNoTracking(), x => x.a.AnsweredByUserId, u => u.Id, (x, us) => new { x.a, x.FirstName, us })
            .SelectMany(x => x.us.DefaultIfEmpty(), (x, u) => new { x.a, x.FirstName, By = u == null ? null : u.DisplayName })
            .ToListAsync(ct);
        return rows.OrderByDescending(r => r.a.CreatedAt).Select(r => new AskDto(r.a.Id, r.a.ChildId, r.FirstName, r.a.Emoji, r.a.Title, r.a.Detail, r.a.ScreenMinutes,
            r.a.Status == AskStatus.Pending && r.a.Day < today ? "Expired" : r.a.Status.ToString(), r.a.Note, FirstName(r.By), r.a.AnsweredAt, r.a.CreatedAt)).ToList();
    }

    public static AskPresetDto ToDto(AskPreset p) => new(p.Id, p.Emoji, p.Title, p.Question, p.Options, p.ScreenMinutes);

    private static string? FirstName(string? displayName) => displayName?.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();

    private async Task<string?> NameOfAsync(Guid askId, CancellationToken ct)
    {
        var userId = await db.ChildAsks.AsNoTracking().Where(a => a.Id == askId).Select(a => a.AnsweredByUserId).FirstOrDefaultAsync(ct);
        return FirstName(await db.Users.AsNoTracking().Where(u => u.Id == userId).Select(u => u.DisplayName).FirstOrDefaultAsync(ct));
    }

    private async Task<bool> ParentsSpeakTurkishAsync(Guid familyId, CancellationToken ct) =>
        await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == familyId && m.Role != FamilyRole.Caregiver)
            .Join(db.Users.AsNoTracking(), m => m.UserId, u => u.Id, (m, u) => u.Locale).FirstOrDefaultAsync(ct) != "en";

    private static string Line(ChildAsk ask) => ask.Detail is null ? $"{ask.Emoji} {ask.Title}" : $"{ask.Emoji} {ask.Title} · {ask.Detail}";

    private async Task NotifyAsync(ChildAsk ask, CancellationToken ct)
    {
        try
        {
            var name = await db.Children.AsNoTracking().Where(c => c.Id == ask.ChildId).Select(c => c.FirstName).FirstAsync(ct);
            var parents = await ParentsAsync(ask.FamilyId, ct);
            foreach (var p in parents)
            {
                var title = p.Locale != "en" ? $"{name} bir şey istiyor" : $"{name} is asking for something";
                await publisher.AddAsync(p.Id, ask.FamilyId, NotificationKind.ChildAsk, title, Line(ask), null, ask.Id, $"ask:{ask.Id:N}:{p.Id:N}", ct);
            }

            await db.SaveChangesAsync(ct);
            await publisher.FlushPushAsync(ct);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Child request notification failed");
        }
    }

    /// <summary>"Ayşe onayladı": the other parents learn the answer, and their request notification goes away.</summary>
    private async Task TellOtherParentsAsync(ChildAsk ask, Guid userId, bool yes, CancellationToken ct)
    {
        try
        {
            var by = FirstName(await db.Users.AsNoTracking().Where(u => u.Id == userId).Select(u => u.DisplayName).FirstAsync(ct));
            var name = await db.Children.AsNoTracking().Where(c => c.Id == ask.ChildId).Select(c => c.FirstName).FirstAsync(ct);
            foreach (var p in (await ParentsAsync(ask.FamilyId, ct)).Where(p => p.Id != userId))
            {
                var tr = p.Locale != "en";
                var title = tr ? (yes ? $"{by} onayladı" : $"{by} hayır dedi") : (yes ? $"{by} said yes" : $"{by} said no");
                await publisher.AddAsync(p.Id, ask.FamilyId, NotificationKind.ChildAskAnswered, title, $"{name}: {Line(ask)}", null, ask.Id,
                    $"asked:{ask.Id:N}:{p.Id:N}", ct);
            }

            await db.SaveChangesAsync(ct);
            await publisher.FlushPushAsync(ct);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Child request answer notification failed");
        }
    }

    /// <summary>Open apps refresh their request cards (same live event as the cherry ledger).</summary>
    private async Task AnnounceAsync(Guid familyId, CancellationToken ct)
    {
        try
        {
            var members = await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == familyId).Select(m => m.UserId).ToListAsync(ct);
            await hub.Clients.Groups(members.Select(ChatHub.UserGroup).ToList()).PointsChanged(new PointsEvent(familyId));
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Realtime request event failed");
        }
    }

    private async Task<List<(Guid Id, string Locale)>> ParentsAsync(Guid familyId, CancellationToken ct) =>
        (await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == familyId && m.Role != FamilyRole.Caregiver)
            .Join(db.Users.AsNoTracking(), m => m.UserId, u => u.Id, (m, u) => new { u.Id, u.Locale }).ToListAsync(ct))
        .Select(p => (p.Id, p.Locale)).ToList();
}

/// <summary>Parents answer the children's requests and edit the ready-made list. Caregivers don't see them.</summary>
[ApiController]
[Authorize(Policy = Policies.FamilyMember)]
[Route("api/v1/families/{familyId:guid}")]
public class AsksController(AskService asks) : ControllerBase
{
    [HttpGet("asks")]
    public Task<IReadOnlyList<AskDto>> List(Guid familyId, [FromQuery] Guid? childId, CancellationToken ct) => asks.ListAsync(familyId, childId, null, ct);

    [HttpPost("asks/{askId:guid}/answer")]
    public Task<AskDto> Answer(Guid familyId, Guid askId, AnswerAskRequest request, CancellationToken ct) =>
        asks.AnswerAsync(familyId, askId, User.UserId(), request, ct);

    [HttpGet("ask-presets")]
    public async Task<IReadOnlyList<AskPresetDto>> Presets(Guid familyId, [FromQuery] string? lang, CancellationToken ct) =>
        (await asks.PresetsAsync(familyId, lang != "en", ct)).Select(AskService.ToDto).ToList();

    [HttpPut("ask-presets")]
    public async Task<IReadOnlyList<AskPresetDto>> SetPresets(Guid familyId, AskPresetsRequest request, CancellationToken ct) =>
        (await asks.SetPresetsAsync(familyId, request.Presets ?? [], ct)).Select(AskService.ToDto).ToList();
}

/// <summary>The child's phone: "Bir şey iste" and the answers.</summary>
[ApiController]
[Authorize(Policy = ChildDeviceAuth.Policy)]
[Route("api/v1/child/asks")]
public class ChildAsksController(AskService asks) : ControllerBase
{
    [HttpGet]
    public async Task<ChildAsksDto> Get([FromQuery] string? lang, CancellationToken ct)
    {
        var presets = await asks.PresetsAsync(User.ChildFamilyId(), lang != "en", ct);
        return new ChildAsksDto(presets.Select(AskService.ToDto).ToList(), await asks.ListAsync(User.ChildFamilyId(), User.ChildId(), null, ct));
    }

    [HttpPost]
    public async Task<ChildAsksDto> Ask(NewAskRequest request, [FromQuery] string? lang, CancellationToken ct)
    {
        await asks.AskAsync(User.ChildFamilyId(), User.ChildId(), request, ct);
        return await Get(lang, ct);
    }
}
