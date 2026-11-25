using Hally.Api.Auth;
using Hally.Api.Common;
using Hally.Api.Features.Messages;
using Hally.Api.Features.Notifications;
using Hally.Domain.Common;
using Hally.Domain.Duties;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.Duties;

/// <param name="Assigned">False when nobody is set for this slot.</param>
/// <param name="IsChange">True when the date's plan differs from the weekday's usual plan.</param>
public record DutySlotDto(string Kind, bool Assigned, Guid? AssigneeUserId, string? AssigneeName, TimeOnly? Time, bool IsChange,
    DateTimeOffset? DoneAt, string? DoneByName);

public record DutyDayDto(DateOnly Date, DutySlotDto DropOff, DutySlotDto PickUp);

public record DutyAdultDto(Guid UserId, string Name);

public record DutyRuleDto(int Weekday, string Kind, Guid? AssigneeUserId, string? AssigneeName, TimeOnly? Time);

/// <param name="Days">Seven days from <see cref="Start"/> (a Monday).</param>
public record DutyWeekDto(DateOnly Start, DateOnly Today, IReadOnlyList<DutyDayDto> Days, IReadOnlyList<DutyRuleDto> Rules, IReadOnlyList<DutyAdultDto> Adults);

/// <summary>Who does it: a family adult (<see cref="AssigneeUserId"/>) or a name; both empty clears the slot.</summary>
public record DutyAssignRequest(Guid? AssigneeUserId = null, string? AssigneeName = null, TimeOnly? Time = null);

/// <summary>Live note that the school run changed; apps reload.</summary>
public record DutiesEvent(Guid FamilyId);

/// <summary>
/// School run duty: who drops the children off and who picks them up. A usual plan per weekday, changes for single
/// dates, and a "done" tap that tells the other adults ("Okuldan alındı · Ayşe"). Live on <c>/hubs/chat</c> (<c>DutiesChanged</c>).
/// </summary>
[ApiController]
[Authorize(Policy = Policies.FamilyMember)]
[Route("api/v1/families/{familyId:guid}/duties")]
public class DutiesController(
    HallyDbContext db,
    IHubContext<ChatHub, IChatClient> hub,
    IPushSender push,
    TimeProvider clock,
    ILogger<DutiesController> logger) : ControllerBase
{
    /// <summary>The week starting <paramref name="start"/> (default: this week's Monday).</summary>
    [CaregiverAllowed]
    [HttpGet]
    public async Task<DutyWeekDto> Week(Guid familyId, [FromQuery] DateOnly? start, CancellationToken ct)
    {
        var today = await Today(familyId, ct);
        var monday = start ?? today.AddDays(-(((int)today.DayOfWeek + 6) % 7));
        var end = monday.AddDays(7);
        var rules = await db.DutyRules.AsNoTracking().Where(r => r.FamilyId == familyId).ToListAsync(ct);
        var overrides = await db.DutyOverrides.AsNoTracking().Where(o => o.FamilyId == familyId && o.Date >= monday && o.Date < end).ToListAsync(ct);
        var done = await db.DutyDones.AsNoTracking().Where(d => d.FamilyId == familyId && d.Date >= monday && d.Date < end).ToListAsync(ct);
        var adults = await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == familyId)
            .Join(db.Users.AsNoTracking(), m => m.UserId, u => u.Id, (m, u) => new DutyAdultDto(u.Id, u.DisplayName)).ToListAsync(ct);
        var names = adults.ToDictionary(a => a.UserId, a => a.Name);

        DutySlotDto Slot(DateOnly date, DutyKind kind)
        {
            var rule = rules.FirstOrDefault(r => r.Weekday == Weekday(date) && r.Kind == kind);
            var change = overrides.FirstOrDefault(o => o.Date == date && o.Kind == kind);
            DutyAssignment? plan = change is not null ? change : rule;
            var tap = done.FirstOrDefault(d => d.Date == date && d.Kind == kind);
            var assigned = plan is not null && (plan.AssigneeUserId is not null || plan.AssigneeName is not null);
            var who = plan?.AssigneeUserId is { } uid ? names.GetValueOrDefault(uid) : plan?.AssigneeName;
            return new DutySlotDto(kind.ToString(), assigned, plan?.AssigneeUserId, who, plan?.Time, change is not null,
                tap?.CreatedAt, tap?.ByUserId is { } by ? names.GetValueOrDefault(by) : null);
        }

        var days = Enumerable.Range(0, 7).Select(i => monday.AddDays(i)).Select(d => new DutyDayDto(d, Slot(d, DutyKind.DropOff), Slot(d, DutyKind.PickUp))).ToList();
        var ruleDtos = rules.OrderBy(r => r.Weekday).ThenBy(r => r.Kind)
            .Select(r => new DutyRuleDto(r.Weekday, r.Kind.ToString(), r.AssigneeUserId,
                r.AssigneeUserId is { } u ? names.GetValueOrDefault(u) : r.AssigneeName, r.Time)).ToList();
        return new DutyWeekDto(monday, today, days, ruleDtos, adults);
    }

    /// <summary>Sets the usual plan for a weekday (0 Monday … 6 Sunday).</summary>
    [HttpPut("rules/{weekday:int}/{kind}")]
    public async Task<DutyWeekDto> SetRule(Guid familyId, int weekday, DutyKind kind, DutyAssignRequest request, CancellationToken ct)
    {
        await EnsureAdult(familyId, request.AssigneeUserId, ct);
        var rule = await db.DutyRules.FirstOrDefaultAsync(r => r.FamilyId == familyId && r.Weekday == weekday && r.Kind == kind, ct);
        if (request.AssigneeUserId is null && string.IsNullOrWhiteSpace(request.AssigneeName))
        {
            if (rule is not null)
            {
                db.DutyRules.Remove(rule);
            }
        }
        else if (rule is null)
        {
            db.DutyRules.Add(new DutyRule(familyId, weekday, kind, request.AssigneeUserId, request.AssigneeName, request.Time, clock.GetUtcNow()));
        }
        else
        {
            rule.Update(request.AssigneeUserId, request.AssigneeName, request.Time);
        }

        await db.SaveChangesAsync(ct);
        await Announce(familyId, ct);
        return await Week(familyId, null, ct);
    }

    /// <summary>Changes one date. An empty assignee means nobody is needed that day (a holiday).</summary>
    [HttpPut("{date}/{kind}")]
    public async Task<DutyWeekDto> SetDay(Guid familyId, DateOnly date, DutyKind kind, DutyAssignRequest request, CancellationToken ct)
    {
        await EnsureAdult(familyId, request.AssigneeUserId, ct);
        var today = await Today(familyId, ct);
        if (date < today.AddDays(-7) || date > today.AddDays(120))
        {
            throw new DomainException("duty.date_invalid", "Changes are for the last week up to four months ahead.");
        }

        var change = await db.DutyOverrides.FirstOrDefaultAsync(o => o.FamilyId == familyId && o.Date == date && o.Kind == kind, ct);
        if (change is null)
        {
            db.DutyOverrides.Add(new DutyOverride(familyId, date, kind, request.AssigneeUserId, request.AssigneeName, request.Time, clock.GetUtcNow()));
        }
        else
        {
            change.Update(request.AssigneeUserId, request.AssigneeName, request.Time);
        }

        await db.SaveChangesAsync(ct);
        await Announce(familyId, ct);
        return await Week(familyId, MondayOf(date), ct);
    }

    /// <summary>Drops the date's change, back to the usual plan.</summary>
    [HttpDelete("{date}/{kind}")]
    public async Task<DutyWeekDto> ResetDay(Guid familyId, DateOnly date, DutyKind kind, CancellationToken ct)
    {
        await db.DutyOverrides.Where(o => o.FamilyId == familyId && o.Date == date && o.Kind == kind).ExecuteDeleteAsync(ct);
        await Announce(familyId, ct);
        return await Week(familyId, MondayOf(date), ct);
    }

    /// <summary>"Dropped off" / "Picked up" for today. Tells the other adults once; a second tap changes nothing.</summary>
    [CaregiverAllowed]
    [HttpPost("today/{kind}/done")]
    public async Task<DutyWeekDto> Done(Guid familyId, DutyKind kind, CancellationToken ct)
    {
        var today = await Today(familyId, ct);
        var me = User.UserId();
        if (!await db.DutyDones.AnyAsync(d => d.FamilyId == familyId && d.Date == today && d.Kind == kind, ct))
        {
            db.DutyDones.Add(new DutyDone(familyId, today, kind, me, clock.GetUtcNow()));
            try
            {
                await db.SaveChangesAsync(ct);
                await TellOthers(familyId, me, kind, ct);
            }
            catch (DbUpdateException)
            {
                // The other adult tapped at the same moment: the unique index kept one.
                db.ChangeTracker.Clear();
            }
        }

        await Announce(familyId, ct);
        return await Week(familyId, null, ct);
    }

    [CaregiverAllowed]
    [HttpDelete("today/{kind}/done")]
    public async Task<DutyWeekDto> Undone(Guid familyId, DutyKind kind, CancellationToken ct)
    {
        var today = await Today(familyId, ct);
        await db.DutyDones.Where(d => d.FamilyId == familyId && d.Date == today && d.Kind == kind).ExecuteDeleteAsync(ct);
        await Announce(familyId, ct);
        return await Week(familyId, null, ct);
    }

    private async Task TellOthers(Guid familyId, Guid me, DutyKind kind, CancellationToken ct)
    {
        try
        {
            var name = await db.Users.AsNoTracking().Where(u => u.Id == me).Select(u => u.DisplayName).FirstAsync(ct);
            var first = name.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? name;
            var others = await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == familyId && m.UserId != me)
                .Join(db.Users.AsNoTracking(), m => m.UserId, u => u.Id, (m, u) => new { u.Id, u.Locale }).ToListAsync(ct);
            var ids = others.Select(o => o.Id).ToList();
            var devices = await db.Devices.AsNoTracking().Where(d => ids.Contains(d.UserId)).ToListAsync(ct);
            var invalid = new List<string>();
            foreach (var user in others)
            {
                var tokens = devices.Where(d => d.UserId == user.Id).Select(d => d.Token).ToList();
                if (tokens.Count == 0)
                {
                    continue;
                }

                var (title, body) = DutyTexts.Done(user.Locale, kind, first);
                var data = new Dictionary<string, string> { ["kind"] = "DutyDone", ["familyId"] = familyId.ToString() };
                invalid.AddRange(await push.SendAsync(tokens, new PushMessage(title, body, data), ct));
            }

            if (invalid.Count > 0)
            {
                await db.Devices.Where(d => invalid.Contains(d.Token)).ExecuteDeleteAsync(ct);
            }
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "School run push failed");
        }
    }

    private static int Weekday(DateOnly d) => ((int)d.DayOfWeek + 6) % 7;

    private static DateOnly MondayOf(DateOnly d) => d.AddDays(-Weekday(d));

    private async Task<DateOnly> Today(Guid familyId, CancellationToken ct)
    {
        var tz = await db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.TimeZoneId).FirstAsync(ct);
        return FamilyTimeZone.LocalDate(clock.GetUtcNow(), tz);
    }

    private async Task EnsureAdult(Guid familyId, Guid? userId, CancellationToken ct)
    {
        if (userId is { } u && !await db.FamilyMembers.AnyAsync(m => m.FamilyId == familyId && m.UserId == u, ct))
        {
            throw new DomainException("duty.assignee_not_member", "Pick an adult of this family.");
        }
    }

    private async Task Announce(Guid familyId, CancellationToken ct)
    {
        try
        {
            var adults = await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == familyId).Select(m => m.UserId).ToListAsync(ct);
            await hub.Clients.Groups(adults.Select(ChatHub.UserGroup).ToList()).DutiesChanged(new DutiesEvent(familyId));
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Realtime duties event failed");
        }
    }
}

public static class DutyTexts
{
    public static (string Title, string Body) Done(string locale, DutyKind kind, string who) => (locale != "en", kind) switch
    {
        (true, DutyKind.DropOff) => ("Okula bırakıldı", $"{who} çocukları okula bıraktı."),
        (true, _) => ("Okuldan alındı", $"{who} çocukları okuldan aldı."),
        (false, DutyKind.DropOff) => ("Dropped off at school", $"{who} dropped the children off."),
        _ => ("Picked up from school", $"{who} picked the children up."),
    };
}
