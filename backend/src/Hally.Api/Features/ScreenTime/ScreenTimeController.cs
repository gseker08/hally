using FluentValidation;
using Hally.Api.Auth;
using Hally.Api.Common;
using Hally.Domain.ScreenTime;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.ScreenTime;

/// <param name="DailyMinutes">Null removes the goal.</param>
public record ScreenTimeGoalRequest(int? DailyMinutes);

public record ScreenTimeEntryRequest(int Minutes);

public class ScreenTimeGoalRequestValidator : AbstractValidator<ScreenTimeGoalRequest>
{
    public ScreenTimeGoalRequestValidator() =>
        RuleFor(x => x.DailyMinutes).InclusiveBetween(Domain.Families.Child.MinScreenGoal, Domain.Families.Child.MaxScreenGoal).When(x => x.DailyMinutes.HasValue);
}

public class ScreenTimeEntryRequestValidator : AbstractValidator<ScreenTimeEntryRequest>
{
    public ScreenTimeEntryRequestValidator() =>
        RuleFor(x => x.Minutes).InclusiveBetween(1, (int)ScreenTimeSession.MaxLength.TotalMinutes);
}

/// <summary>
/// Hand-operated screen time timer per child. The server keeps the timer, so every adult sees the same running
/// time; each change is announced live on <c>/hubs/chat</c> (<c>ScreenTimeChanged</c>). Hally does not limit the
/// device: it only counts and tells the parents when today's goal is reached.
/// </summary>
[ApiController]
[Authorize(Policy = Policies.FamilyMember)]
[Route("api/v1/families/{familyId:guid}")]
public class ScreenTimeController(HallyDbContext db, ScreenTimeService screenTime, TimeProvider clock) : ControllerBase
{
    /// <summary>Today's totals (family-local day) and running timers for every child.</summary>
    [HttpGet("screen-time")]
    public Task<ScreenTimeTodayDto> Today(Guid familyId, CancellationToken ct) => screenTime.TodayAsync(familyId, ct);

    /// <summary>Daily totals for the week starting <paramref name="start"/> (default: this week's Monday).</summary>
    [HttpGet("screen-time/week")]
    public Task<ScreenTimeWeekDto> Week(Guid familyId, [FromQuery] DateOnly? start, CancellationToken ct) => screenTime.WeekAsync(familyId, start, ct);

    /// <summary>Starts the child's timer. Already running (for example the other parent just started it) is not an
    /// error: the current status comes back either way.</summary>
    [HttpPost("children/{childId:guid}/screen-time/start")]
    public async Task<ChildScreenTimeDto> Start(Guid familyId, Guid childId, CancellationToken ct)
    {
        await EnsureChild(familyId, childId, ct);
        var now = clock.GetUtcNow();
        if (!await db.ScreenTimeSessions.AnyAsync(s => s.ChildId == childId && s.EndedAt == null, ct))
        {
            db.ScreenTimeSessions.Add(new ScreenTimeSession(familyId, childId, User.UserId(), now));
            try
            {
                await db.SaveChangesAsync(ct);
            }
            catch (DbUpdateException)
            {
                // Lost a race with another Start: the unique index on running timers kept just one.
                db.ChangeTracker.Clear();
            }
        }

        return await Changed(familyId, childId, ct);
    }

    /// <summary>Stops the child's timer. Already stopped is not an error.</summary>
    [HttpPost("children/{childId:guid}/screen-time/stop")]
    public async Task<ChildScreenTimeDto> Stop(Guid familyId, Guid childId, CancellationToken ct)
    {
        await EnsureChild(familyId, childId, ct);
        var running = await db.ScreenTimeSessions.FirstOrDefaultAsync(s => s.ChildId == childId && s.EndedAt == null, ct);
        if (running is not null)
        {
            running.Stop(User.UserId(), clock.GetUtcNow());
            await db.SaveChangesAsync(ct);
        }

        return await Changed(familyId, childId, ct);
    }

    /// <summary>Adds finished minutes ending now, for when nobody started the timer.</summary>
    [HttpPost("children/{childId:guid}/screen-time/entries")]
    public async Task<ChildScreenTimeDto> AddEntry(Guid familyId, Guid childId, ScreenTimeEntryRequest request, CancellationToken ct)
    {
        await EnsureChild(familyId, childId, ct);
        db.ScreenTimeSessions.Add(ScreenTimeSession.Manual(familyId, childId, User.UserId(), TimeSpan.FromMinutes(request.Minutes), clock.GetUtcNow()));
        await db.SaveChangesAsync(ct);
        return await Changed(familyId, childId, ct);
    }

    /// <summary>Sets or clears the child's daily goal.</summary>
    [HttpPut("children/{childId:guid}/screen-time/goal")]
    public async Task<ChildScreenTimeDto> SetGoal(Guid familyId, Guid childId, ScreenTimeGoalRequest request, CancellationToken ct)
    {
        var child = await db.Children.FirstOrDefaultAsync(c => c.FamilyId == familyId && c.Id == childId, ct)
                    ?? throw new NotFoundException("child.not_found", "Child not found.");
        child.SetScreenTimeGoal(request.DailyMinutes);
        await db.SaveChangesAsync(ct);
        return await Changed(familyId, childId, ct);
    }

    private async Task EnsureChild(Guid familyId, Guid childId, CancellationToken ct)
    {
        if (!await db.Children.AnyAsync(c => c.FamilyId == familyId && c.Id == childId, ct))
        {
            throw new NotFoundException("child.not_found", "Child not found.");
        }
    }

    private async Task<ChildScreenTimeDto> Changed(Guid familyId, Guid childId, CancellationToken ct)
    {
        var status = await screenTime.StatusAsync(familyId, childId, ct);
        await screenTime.AnnounceAsync(familyId, status, ct);
        await screenTime.NotifyIfGoalReachedAsync(familyId, status, ct);
        return status;
    }
}
