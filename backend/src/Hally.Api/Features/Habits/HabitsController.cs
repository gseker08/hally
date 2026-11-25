using FluentValidation;
using Hally.Api.Auth;
using Hally.Api.Common;
using Hally.Api.Features.Messages;
using Hally.Domain.Common;
using Hally.Domain.Habits;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.Habits;

/// <param name="Days">Weekday mask, Monday bit 0.</param>
/// <param name="LastSeven">The last seven days, oldest first: true done, false missed or not yet, null not scheduled.</param>
public record HabitDto(Guid Id, Guid ChildId, string Title, int Days, bool DoneToday, bool DueToday, int Streak, int Best, IReadOnlyList<bool?> LastSeven);

public record HabitsDto(DateOnly Today, IReadOnlyList<HabitDto> Habits);

public record HabitRequest(Guid ChildId, string Title, int Days = Habit.EveryDay);

/// <param name="Day">Defaults to today; up to 6 days back.</param>
public record HabitCheckRequest(DateOnly? Day = null);

/// <summary>Live note that habits changed; apps reload.</summary>
public record HabitsEvent(Guid FamilyId);

public class HabitRequestValidator : AbstractValidator<HabitRequest>
{
    public HabitRequestValidator()
    {
        RuleFor(x => x.Title).NotEmpty().MaximumLength(60);
        RuleFor(x => x.Days).InclusiveBetween(1, Habit.EveryDay);
    }
}

/// <summary>
/// Daily habits per child with streaks. A parent taps the habit when it is done (or for a day in the last week they
/// forgot); unscheduled weekdays do not break a streak. Changes go out live on <c>/hubs/chat</c> (<c>HabitsChanged</c>).
/// </summary>
[ApiController]
[Authorize(Policy = Policies.FamilyMember)]
[Route("api/v1/families/{familyId:guid}/habits")]
public class HabitsController(HallyDbContext db, IHubContext<ChatHub, IChatClient> hub, TimeProvider clock, ILogger<HabitsController> logger) : ControllerBase
{
    /// <summary>How far back streaks look.</summary>
    private const int HistoryDays = 120;

    [CaregiverAllowed]
    [HttpGet]
    public async Task<HabitsDto> List(Guid familyId, CancellationToken ct)
    {
        var today = await Today(familyId, ct);
        var since = today.AddDays(-HistoryDays);
        var access = HttpContext.Access();
        var habits = (await db.Habits.AsNoTracking().Where(h => h.FamilyId == familyId).OrderBy(h => h.CreatedAt).ToListAsync(ct))
            .Where(h => access.SeesChild(h.ChildId)).ToList();
        var checks = await db.HabitChecks.AsNoTracking().Where(c => c.FamilyId == familyId && c.Day >= since)
            .Select(c => new { c.HabitId, c.Day }).ToListAsync(ct);
        var byHabit = checks.GroupBy(c => c.HabitId).ToDictionary(g => g.Key, g => (ISet<DateOnly>)g.Select(c => c.Day).ToHashSet());
        return new HabitsDto(today, habits.Select(h =>
        {
            var done = byHabit.GetValueOrDefault(h.Id) ?? new HashSet<DateOnly>();
            var lastSeven = Enumerable.Range(-6, 7).Select(i => today.AddDays(i)).Select(d => h.IsScheduled(d) ? done.Contains(d) : (bool?)null).ToList();
            return new HabitDto(h.Id, h.ChildId, h.Title, h.Days, done.Contains(today), h.IsScheduled(today), h.Streak(done, today, since),
                h.Best(done, today, since), lastSeven);
        }).ToList());
    }

    [HttpPost]
    [ProducesResponseType<HabitsDto>(201)]
    public async Task<IActionResult> Add(Guid familyId, HabitRequest request, CancellationToken ct)
    {
        if (!await db.Children.AnyAsync(c => c.FamilyId == familyId && c.Id == request.ChildId, ct))
        {
            throw new NotFoundException("child.not_found", "Child not found.");
        }

        db.Habits.Add(new Habit(familyId, request.ChildId, request.Title, request.Days, clock.GetUtcNow()));
        await db.SaveChangesAsync(ct);
        await Announce(familyId, ct);
        return StatusCode(201, await List(familyId, ct));
    }

    [HttpDelete("{habitId:guid}")]
    public async Task<HabitsDto> Delete(Guid familyId, Guid habitId, CancellationToken ct)
    {
        db.Habits.Remove(await Find(familyId, habitId, ct));
        await db.SaveChangesAsync(ct);
        await Announce(familyId, ct);
        return await List(familyId, ct);
    }

    /// <summary>Marks the habit done for a day. Already done is not an error.</summary>
    [CaregiverAllowed]
    [HttpPost("{habitId:guid}/check")]
    public async Task<HabitsDto> Check(Guid familyId, Guid habitId, HabitCheckRequest request, CancellationToken ct)
    {
        var habit = await Find(familyId, habitId, ct);
        var day = await Day(familyId, request.Day, ct);
        if (!await db.HabitChecks.AnyAsync(c => c.HabitId == habitId && c.Day == day, ct))
        {
            db.HabitChecks.Add(new HabitCheck(habit, day, User.UserId(), clock.GetUtcNow()));
            try
            {
                await db.SaveChangesAsync(ct);
            }
            catch (DbUpdateException)
            {
                // The other parent tapped at the same moment: the unique index kept one.
                db.ChangeTracker.Clear();
            }
        }

        await Announce(familyId, ct);
        return await List(familyId, ct);
    }

    [CaregiverAllowed]
    [HttpDelete("{habitId:guid}/check")]
    public async Task<HabitsDto> Uncheck(Guid familyId, Guid habitId, [FromQuery] DateOnly? day, CancellationToken ct)
    {
        await Find(familyId, habitId, ct);
        var d = await Day(familyId, day, ct);
        await db.HabitChecks.Where(c => c.HabitId == habitId && c.Day == d).ExecuteDeleteAsync(ct);
        await Announce(familyId, ct);
        return await List(familyId, ct);
    }

    private async Task<DateOnly> Day(Guid familyId, DateOnly? requested, CancellationToken ct)
    {
        var today = await Today(familyId, ct);
        var day = requested ?? today;
        if (day > today || day < today.AddDays(-6))
        {
            throw new DomainException("habit.day_invalid", "Habits can be marked for today and the 6 days before.");
        }

        return day;
    }

    private async Task<DateOnly> Today(Guid familyId, CancellationToken ct)
    {
        var tz = await db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.TimeZoneId).FirstAsync(ct);
        return FamilyTimeZone.LocalDate(clock.GetUtcNow(), tz);
    }

    private async Task<Habit> Find(Guid familyId, Guid habitId, CancellationToken ct) =>
        await db.Habits.FirstOrDefaultAsync(h => h.Id == habitId && h.FamilyId == familyId, ct)
        ?? throw new NotFoundException("habit.not_found", "Habit not found.");

    private async Task Announce(Guid familyId, CancellationToken ct)
    {
        try
        {
            var adults = await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == familyId).Select(m => m.UserId).ToListAsync(ct);
            await hub.Clients.Groups(adults.Select(ChatHub.UserGroup).ToList()).HabitsChanged(new HabitsEvent(familyId));
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Realtime habits event failed");
        }
    }
}
