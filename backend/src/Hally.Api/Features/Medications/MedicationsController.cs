using System.Data;
using FluentValidation;
using Hally.Api.Auth;
using Hally.Api.Common;
using Hally.Domain.Health;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.Medications;

public record SaveMedicationRequest(Guid ChildId, string Name, string? Dose, int MinIntervalMinutes, int? MaxDosesPerDay = null,
    bool RemindNextDose = true, string? Notes = null, bool Active = true);

/// <param name="GivenAt">Defaults to now; earlier for "I gave it an hour ago".</param>
/// <param name="Force">Save even though it is too soon (the adult confirmed the warning).</param>
public record GiveDoseRequest(DateTimeOffset? GivenAt = null, string? Note = null, bool Force = false);

public class SaveMedicationRequestValidator : AbstractValidator<SaveMedicationRequest>
{
    public SaveMedicationRequestValidator()
    {
        RuleFor(x => x.Name).NotEmpty().MaximumLength(60);
        RuleFor(x => x.Dose).MaximumLength(40);
        RuleFor(x => x.Notes).MaximumLength(300);
        RuleFor(x => x.MinIntervalMinutes).InclusiveBetween(Medication.MinInterval, Medication.MaxInterval);
        RuleFor(x => x.MaxDosesPerDay).InclusiveBetween(1, 24).When(x => x.MaxDosesPerDay.HasValue);
    }
}

public class GiveDoseRequestValidator : AbstractValidator<GiveDoseRequest>
{
    public GiveDoseRequestValidator() => RuleFor(x => x.Note).MaximumLength(200);
}

/// <summary>
/// Medication tracking: which medicine each child takes, every dose given and by whom, and a warning when a dose
/// would come sooner than the parents' own interval. Changes are announced live on <c>/hubs/chat</c>
/// (<c>MedicationChanged</c>) and a given dose is pushed to the other adults.
/// </summary>
[ApiController]
[Authorize(Policy = Policies.FamilyMember)]
[Route("api/v1/families/{familyId:guid}/medications")]
public class MedicationsController(HallyDbContext db, MedicationService medications, TimeProvider clock) : ControllerBase
{
    [HttpGet]
    public Task<List<MedicationDto>> List(Guid familyId, [FromQuery] bool includeInactive, CancellationToken ct) =>
        medications.ListAsync(familyId, includeInactive, ct);

    [HttpPost]
    [Idempotent]
    [ProducesResponseType<MedicationDto>(201)]
    public async Task<IActionResult> Create(Guid familyId, SaveMedicationRequest request, CancellationToken ct)
    {
        await EnsureChild(familyId, request.ChildId, ct);
        var med = new Medication(familyId, request.ChildId, User.UserId(), request.Name, request.Dose, request.MinIntervalMinutes,
            request.MaxDosesPerDay, request.RemindNextDose, request.Notes, clock.GetUtcNow());
        db.Medications.Add(med);
        await db.SaveChangesAsync(ct);
        await medications.AnnounceAsync(familyId, med.Id, ct);
        return StatusCode(201, await medications.ToDtoAsync(med, ct));
    }

    [HttpPut("{medicationId:guid}")]
    public async Task<MedicationDto> Update(Guid familyId, Guid medicationId, SaveMedicationRequest request, CancellationToken ct)
    {
        var med = await Find(familyId, medicationId, ct);
        if (request.ChildId != med.ChildId)
        {
            throw new Domain.Common.DomainException("medication.child_fixed", "A medication cannot move to another child; add a new one.");
        }

        med.Update(request.Name, request.Dose, request.MinIntervalMinutes, request.MaxDosesPerDay, request.RemindNextDose, request.Notes, request.Active);
        await db.SaveChangesAsync(ct);
        await medications.AnnounceAsync(familyId, med.Id, ct);
        return await medications.ToDtoAsync(med, ct);
    }

    /// <summary>Deletes the medication and its dose history. To end a course but keep the history, set Active to false.</summary>
    [HttpDelete("{medicationId:guid}")]
    public async Task<IActionResult> Delete(Guid familyId, Guid medicationId, CancellationToken ct)
    {
        db.Medications.Remove(await Find(familyId, medicationId, ct));
        await db.SaveChangesAsync(ct);
        await medications.AnnounceAsync(familyId, medicationId, ct);
        return NoContent();
    }

    /// <summary>Doses of the last <paramref name="days"/> days, newest first.</summary>
    [HttpGet("{medicationId:guid}/doses")]
    public async Task<List<DoseDto>> Doses(Guid familyId, Guid medicationId, [FromQuery] int days = 14, CancellationToken ct = default)
    {
        await Find(familyId, medicationId, ct);
        var since = clock.GetUtcNow().AddDays(-Math.Clamp(days, 1, 90));
        var doses = await db.MedicationDoses.AsNoTracking().Where(d => d.MedicationId == medicationId && d.GivenAt >= since)
            .OrderByDescending(d => d.GivenAt).Take(200).ToListAsync(ct);
        var result = new List<DoseDto>();
        foreach (var d in doses)
        {
            result.Add(await medications.ToDtoAsync(d, ct));
        }

        return result;
    }

    /// <summary>
    /// Records a dose. When it comes sooner than the interval (or past the daily limit) and <c>force</c> is not set,
    /// nothing is saved and 409 comes back with the last dose, so the app can ask "Mehmet gave it at 14:05, save
    /// anyway?". Two parents pressing at the same moment are serialized, so the second one gets that question.
    /// </summary>
    [HttpPost("{medicationId:guid}/doses")]
    [ProducesResponseType<MedicationDto>(201)]
    [ProducesResponseType<DoseWarningDto>(409)]
    public async Task<IActionResult> Give(Guid familyId, Guid medicationId, GiveDoseRequest request, CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        var at = request.GivenAt ?? now;
        if (at > now.AddMinutes(5))
        {
            throw new Domain.Common.DomainException("medication.dose_in_future", "A dose cannot be recorded in the future.");
        }

        await using var tx = await db.Database.BeginTransactionAsync(IsolationLevel.ReadCommitted, ct);
        // Row lock on the medication: concurrent doses for it wait here, then see each other.
        var med = await db.Medications.FromSqlInterpolated($"SELECT * FROM medications WHERE id = {medicationId} AND family_id = {familyId} FOR UPDATE")
                      .FirstOrDefaultAsync(ct)
                  ?? throw new NotFoundException("medication.not_found", "Medication not found.");
        var recent = await medications.RecentDosesAsync(medicationId, at, ct);
        if (!request.Force && med.Check(recent, at) is { } warning)
        {
            await tx.RollbackAsync(ct);
            return Conflict(new DoseWarningDto(
                warning.Kind == DoseWarningKind.TooSoon ? "medication.too_soon" : "medication.daily_limit",
                warning.Kind.ToString(),
                await medications.ToDtoAsync(warning.Nearest, ct),
                warning.NextAllowedAt,
                await medications.ToDtoAsync(med, ct)));
        }

        var dose = new MedicationDose(med, User.UserId(), at, request.Note, request.Force && med.Check(recent, at) is not null, now);
        db.MedicationDoses.Add(dose);
        await db.SaveChangesAsync(ct);
        await tx.CommitAsync(ct);

        await medications.AnnounceAsync(familyId, med.Id, ct);
        await medications.PushDoseGivenAsync(med, dose, User.UserId(), ct);
        return StatusCode(201, await medications.ToDtoAsync(med, ct));
    }

    /// <summary>Removes a dose recorded by mistake.</summary>
    [HttpDelete("{medicationId:guid}/doses/{doseId:guid}")]
    public async Task<IActionResult> DeleteDose(Guid familyId, Guid medicationId, Guid doseId, CancellationToken ct)
    {
        var dose = await db.MedicationDoses.FirstOrDefaultAsync(d => d.Id == doseId && d.MedicationId == medicationId && d.FamilyId == familyId, ct)
                   ?? throw new NotFoundException("medication.dose_not_found", "Dose not found.");
        db.MedicationDoses.Remove(dose);
        await db.SaveChangesAsync(ct);
        await medications.AnnounceAsync(familyId, medicationId, ct);
        return NoContent();
    }

    private async Task<Medication> Find(Guid familyId, Guid medicationId, CancellationToken ct) =>
        await db.Medications.FirstOrDefaultAsync(m => m.FamilyId == familyId && m.Id == medicationId, ct)
        ?? throw new NotFoundException("medication.not_found", "Medication not found.");

    private async Task EnsureChild(Guid familyId, Guid childId, CancellationToken ct)
    {
        if (!await db.Children.AnyAsync(c => c.FamilyId == familyId && c.Id == childId, ct))
        {
            throw new NotFoundException("child.not_found", "Child not found.");
        }
    }
}
