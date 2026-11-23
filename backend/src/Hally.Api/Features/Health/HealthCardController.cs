using Hally.Api.Auth;
using Hally.Api.Common;
using Hally.Api.Features.Messages;
using Hally.Domain.Common;
using Hally.Domain.Health;
using Hally.Domain.Notifications;
using Hally.Domain.Planning;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.Health;

public record HealthProfileDto(string? BloodType, string? Allergies, string? Conditions, string? DoctorName, string? DoctorPhone, string? Notes,
    DateTimeOffset? UpdatedAt);

public record VaccineDto(Guid Id, string Name, DateOnly? DueOn, DateOnly? GivenOn, string? Note, bool Overdue);

public record GrowthDto(Guid Id, DateOnly MeasuredOn, decimal? HeightCm, decimal? WeightKg, decimal? HeadCm);

public record AppointmentDto(Guid Id, Guid EventId, string Title, DateTimeOffset StartsAt, string? Location, string? Doctor, bool Past);

/// <param name="Appointments">Upcoming ones (soonest first), then the last 5 past ones.</param>
/// <param name="Growth">Oldest first, for a chart.</param>
public record HealthCardDto(Guid ChildId, HealthProfileDto Profile, IReadOnlyList<VaccineDto> Vaccines, IReadOnlyList<GrowthDto> Growth,
    IReadOnlyList<AppointmentDto> Appointments);

public record SaveHealthProfileRequest(string? BloodType, string? Allergies, string? Conditions, string? DoctorName, string? DoctorPhone, string? Notes);

public record SaveVaccineRequest(string Name, DateOnly? DueOn, DateOnly? GivenOn, string? Note);

public record VaccineGivenRequest(DateOnly? On = null);

public record AddGrowthRequest(decimal? HeightCm, decimal? WeightKg, decimal? HeadCm, DateOnly? MeasuredOn = null);

/// <param name="Remind">Remind every adult the evening before (19:00), or 2 hours before when that has passed.</param>
public record AddAppointmentRequest(string Title, DateTimeOffset StartsAt, string? Location = null, string? Doctor = null, bool Remind = true);

public record HealthEvent(Guid FamilyId, Guid ChildId);

/// <summary>
/// A child's health card: the basics (blood type, allergies, doctor), vaccines, growth and doctor's appointments. Hally keeps
/// what the parents enter and gives no medical advice: no vaccine schedule, no percentiles. Live on <c>/hubs/chat</c> (<c>HealthChanged</c>).
/// </summary>
[ApiController]
[Authorize(Policy = Policies.FamilyMember)]
[Route("api/v1/families/{familyId:guid}/children/{childId:guid}/health")]
public class HealthCardController(HallyDbContext db, IHubContext<ChatHub, IChatClient> hub, TimeProvider clock, ILogger<HealthCardController> logger)
    : ControllerBase
{
    public const int ReminderHour = 19;

    [HttpGet]
    public async Task<HealthCardDto> Card(Guid familyId, Guid childId, CancellationToken ct)
    {
        var tz = await ChildZone(familyId, childId, ct);
        var now = clock.GetUtcNow();
        var today = FamilyTimeZone.LocalDate(now, tz);
        var profile = await db.HealthProfiles.AsNoTracking().FirstOrDefaultAsync(p => p.ChildId == childId, ct);
        var vaccines = await db.Vaccines.AsNoTracking().Where(v => v.ChildId == childId).ToListAsync(ct);
        var growth = await db.GrowthMeasurements.AsNoTracking().Where(g => g.ChildId == childId)
            .OrderByDescending(g => g.MeasuredOn).ThenByDescending(g => g.CreatedAt).Take(100).ToListAsync(ct);
        var appointments = await db.HealthAppointments.AsNoTracking().Where(a => a.ChildId == childId)
            .Join(db.Events.AsNoTracking(), a => a.EventId, e => e.Id, (a, e) => new { a.Id, a.EventId, e.Title, e.StartsAt, e.Location, a.Doctor })
            .ToListAsync(ct);

        var upcoming = appointments.Where(a => a.StartsAt >= now).OrderBy(a => a.StartsAt);
        var past = appointments.Where(a => a.StartsAt < now).OrderByDescending(a => a.StartsAt).Take(5);
        return new HealthCardDto(
            childId,
            profile is null
                ? new HealthProfileDto(null, null, null, null, null, null, null)
                : new HealthProfileDto(profile.BloodType, profile.Allergies, profile.Conditions, profile.DoctorName, profile.DoctorPhone, profile.Notes,
                    profile.UpdatedAt),
            vaccines
                .OrderBy(v => v.IsGiven)
                .ThenBy(v => v.IsGiven ? DateOnly.MinValue : v.DueOn)
                .ThenByDescending(v => v.GivenOn)
                .Select(v => new VaccineDto(v.Id, v.Name, v.DueOn, v.GivenOn, v.Note, !v.IsGiven && v.DueOn < today))
                .ToList(),
            growth.OrderBy(g => g.MeasuredOn).Select(g => new GrowthDto(g.Id, g.MeasuredOn, g.HeightCm, g.WeightKg, g.HeadCm)).ToList(),
            upcoming.Concat(past).Select(a => new AppointmentDto(a.Id, a.EventId, a.Title, a.StartsAt, a.Location, a.Doctor, a.StartsAt < now)).ToList());
    }

    [HttpPut("profile")]
    public async Task<HealthCardDto> SaveProfile(Guid familyId, Guid childId, SaveHealthProfileRequest request, CancellationToken ct)
    {
        await ChildZone(familyId, childId, ct);
        var now = clock.GetUtcNow();
        var profile = await db.HealthProfiles.FirstOrDefaultAsync(p => p.ChildId == childId, ct);
        if (profile is null)
        {
            profile = new HealthProfile(familyId, childId, now);
            db.HealthProfiles.Add(profile);
        }

        profile.Update(request.BloodType, request.Allergies, request.Conditions, request.DoctorName, request.DoctorPhone, request.Notes, now);
        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (DbUpdateException)
        {
            // Both parents saved the first version at once: the other one won; apply ours on top.
            db.ChangeTracker.Clear();
            profile = await db.HealthProfiles.FirstAsync(p => p.ChildId == childId, ct);
            profile.Update(request.BloodType, request.Allergies, request.Conditions, request.DoctorName, request.DoctorPhone, request.Notes, now);
            await db.SaveChangesAsync(ct);
        }

        return await Changed(familyId, childId, ct);
    }

    [HttpPost("vaccines")]
    [ProducesResponseType<HealthCardDto>(201)]
    public async Task<IActionResult> AddVaccine(Guid familyId, Guid childId, SaveVaccineRequest request, CancellationToken ct)
    {
        var today = FamilyTimeZone.LocalDate(clock.GetUtcNow(), await ChildZone(familyId, childId, ct));
        db.Vaccines.Add(new VaccineRecord(familyId, childId, request.Name, request.DueOn, request.GivenOn, request.Note, User.UserId(), today, clock.GetUtcNow()));
        await db.SaveChangesAsync(ct);
        return StatusCode(201, await Changed(familyId, childId, ct));
    }

    [HttpPut("vaccines/{vaccineId:guid}")]
    public async Task<HealthCardDto> UpdateVaccine(Guid familyId, Guid childId, Guid vaccineId, SaveVaccineRequest request, CancellationToken ct)
    {
        var today = FamilyTimeZone.LocalDate(clock.GetUtcNow(), await ChildZone(familyId, childId, ct));
        var vaccine = await Vaccine(childId, vaccineId, ct);
        vaccine.Update(request.Name, request.DueOn, request.GivenOn, request.Note, today);
        await db.SaveChangesAsync(ct);
        return await Changed(familyId, childId, ct);
    }

    /// <summary>Marks a planned vaccine as given (today unless <c>on</c> is set).</summary>
    [HttpPost("vaccines/{vaccineId:guid}/given")]
    public async Task<HealthCardDto> VaccineGiven(Guid familyId, Guid childId, Guid vaccineId, VaccineGivenRequest request, CancellationToken ct)
    {
        var today = FamilyTimeZone.LocalDate(clock.GetUtcNow(), await ChildZone(familyId, childId, ct));
        var vaccine = await Vaccine(childId, vaccineId, ct);
        vaccine.MarkGiven(request.On ?? today, today);
        await db.SaveChangesAsync(ct);
        return await Changed(familyId, childId, ct);
    }

    [HttpDelete("vaccines/{vaccineId:guid}")]
    public async Task<HealthCardDto> DeleteVaccine(Guid familyId, Guid childId, Guid vaccineId, CancellationToken ct)
    {
        await ChildZone(familyId, childId, ct);
        await db.Vaccines.Where(v => v.Id == vaccineId && v.ChildId == childId).ExecuteDeleteAsync(ct);
        return await Changed(familyId, childId, ct);
    }

    [HttpPost("growth")]
    [ProducesResponseType<HealthCardDto>(201)]
    public async Task<IActionResult> AddGrowth(Guid familyId, Guid childId, AddGrowthRequest request, CancellationToken ct)
    {
        var today = FamilyTimeZone.LocalDate(clock.GetUtcNow(), await ChildZone(familyId, childId, ct));
        db.GrowthMeasurements.Add(new GrowthMeasurement(familyId, childId, request.MeasuredOn ?? today, request.HeightCm, request.WeightKg, request.HeadCm,
            User.UserId(), today, clock.GetUtcNow()));
        await db.SaveChangesAsync(ct);
        return StatusCode(201, await Changed(familyId, childId, ct));
    }

    [HttpDelete("growth/{measurementId:guid}")]
    public async Task<HealthCardDto> DeleteGrowth(Guid familyId, Guid childId, Guid measurementId, CancellationToken ct)
    {
        await ChildZone(familyId, childId, ct);
        await db.GrowthMeasurements.Where(g => g.Id == measurementId && g.ChildId == childId).ExecuteDeleteAsync(ct);
        return await Changed(familyId, childId, ct);
    }

    /// <summary>Adds a calendar event tagged with the child (one hour long), marks it as a health appointment and, by default,
    /// schedules a reminder for every adult.</summary>
    [HttpPost("appointments")]
    [ProducesResponseType<HealthCardDto>(201)]
    public async Task<IActionResult> AddAppointment(Guid familyId, Guid childId, AddAppointmentRequest request, CancellationToken ct)
    {
        var tz = await ChildZone(familyId, childId, ct);
        var now = clock.GetUtcNow();
        if (string.IsNullOrWhiteSpace(request.Title) || request.Title.Trim().Length > 120)
        {
            throw new DomainException("appointment.title_invalid", "Title must be 1-120 characters.");
        }

        if (request.StartsAt < now.AddDays(-1) || request.StartsAt > now.AddDays(400))
        {
            throw new DomainException("appointment.time_invalid", "The appointment must be between yesterday and 400 days ahead.");
        }

        var userId = User.UserId();
        var evt = new CalendarEvent(familyId, userId, request.Title.Trim(), request.StartsAt, request.StartsAt.AddHours(1), false, request.Location, [childId]);
        db.Events.Add(evt);
        db.HealthAppointments.Add(new HealthAppointment(familyId, childId, evt.Id, request.Doctor, now));
        db.AuditEntries.Add(new AuditEntry { FamilyId = familyId, ActorUserId = userId, Action = "event.created", EntityType = "event", EntityId = evt.Id, At = now });
        if (request.Remind && ReminderTime(request.StartsAt, tz, now) is { } fireAt)
        {
            db.Reminders.Add(new Reminder(familyId, userId, ReminderTarget.Event, evt.Id, null, fireAt, now));
        }

        await db.SaveChangesAsync(ct);
        return StatusCode(201, await Changed(familyId, childId, ct));
    }

    /// <summary>Deletes the appointment and its calendar event.</summary>
    [HttpDelete("appointments/{appointmentId:guid}")]
    public async Task<HealthCardDto> DeleteAppointment(Guid familyId, Guid childId, Guid appointmentId, CancellationToken ct)
    {
        await ChildZone(familyId, childId, ct);
        var appointment = await db.HealthAppointments.FirstOrDefaultAsync(a => a.Id == appointmentId && a.ChildId == childId, ct)
                          ?? throw new NotFoundException("appointment.not_found", "Appointment not found.");
        // The appointment row goes with its event (cascade).
        await db.Events.Where(e => e.Id == appointment.EventId && e.FamilyId == familyId).ExecuteDeleteAsync(ct);
        db.AuditEntries.Add(new AuditEntry { FamilyId = familyId, ActorUserId = User.UserId(), Action = "event.deleted", EntityType = "event", EntityId = appointment.EventId, At = clock.GetUtcNow() });
        db.Entry(appointment).State = EntityState.Detached;
        await db.SaveChangesAsync(ct);
        return await Changed(familyId, childId, ct);
    }

    /// <summary>19:00 family time the evening before; if that has passed, 2 hours before; null when both have passed.</summary>
    public static DateTimeOffset? ReminderTime(DateTimeOffset startsAt, string timeZoneId, DateTimeOffset now)
    {
        var day = FamilyTimeZone.LocalDate(startsAt, timeZoneId).AddDays(-1);
        var evening = FamilyTimeZone.StartOfDay(day, timeZoneId).AddHours(ReminderHour);
        if (evening > now)
        {
            return evening;
        }

        var before = startsAt.AddHours(-2);
        return before > now ? before : null;
    }

    private async Task<VaccineRecord> Vaccine(Guid childId, Guid vaccineId, CancellationToken ct) =>
        await db.Vaccines.FirstOrDefaultAsync(v => v.Id == vaccineId && v.ChildId == childId, ct)
        ?? throw new NotFoundException("vaccine.not_found", "Vaccine not found.");

    /// <summary>Checks the child belongs to the family and returns the family's time zone.</summary>
    private async Task<string> ChildZone(Guid familyId, Guid childId, CancellationToken ct)
    {
        if (!await db.Children.AnyAsync(c => c.Id == childId && c.FamilyId == familyId, ct))
        {
            throw new NotFoundException("child.not_found", "Child not found.");
        }

        return await db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.TimeZoneId).FirstAsync(ct);
    }

    private async Task<HealthCardDto> Changed(Guid familyId, Guid childId, CancellationToken ct)
    {
        try
        {
            var adults = await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == familyId).Select(m => m.UserId).ToListAsync(ct);
            await hub.Clients.Groups(adults.Select(ChatHub.UserGroup).ToList()).HealthChanged(new HealthEvent(familyId, childId));
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Realtime health event failed");
        }

        return await Card(familyId, childId, ct);
    }
}
