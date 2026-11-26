using Hally.Api.Features.Messages;
using Hally.Api.Features.Notifications;
using Hally.Domain.Common;
using Hally.Domain.Health;
using Hally.Domain.Notifications;
using Hally.Domain.Users;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.Medications;

public record DoseDto(Guid Id, Guid MedicationId, DateTimeOffset GivenAt, Guid? GivenByUserId, string? GivenByName, string? Note, bool OverrodeWarning);

/// <param name="NextAllowedAt">When the next dose fits the parents' rule; null when it may be given now.</param>
public record MedicationDto(
    Guid Id,
    Guid ChildId,
    string Name,
    string? Dose,
    int MinIntervalMinutes,
    int? MaxDosesPerDay,
    bool RemindNextDose,
    string? Notes,
    bool Active,
    DoseDto? LastDose,
    int DosesLast24h,
    DateTimeOffset? NextAllowedAt);

/// <summary>Body of a 409 when a dose comes too soon: what was given last and when the next one fits.</summary>
public record DoseWarningDto(string Code, string Kind, DoseDto LastDose, DateTimeOffset? NextAllowedAt, MedicationDto Medication);

/// <summary>Live note that a family's medications or doses changed; apps reload the list.</summary>
public record MedicationEvent(Guid FamilyId, Guid MedicationId);

public class MedicationService(
    HallyDbContext db,
    IHubContext<ChatHub, IChatClient> hub,
    IPushSender push,
    TimeProvider clock,
    ILogger<MedicationService> logger)
{
    public async Task<List<MedicationDto>> ListAsync(Guid familyId, bool includeInactive, CancellationToken ct)
    {
        var meds = await db.Medications.AsNoTracking()
            .Where(m => m.FamilyId == familyId && (includeInactive || m.Active))
            .OrderByDescending(m => m.Active).ThenBy(m => m.CreatedAt)
            .ToListAsync(ct);
        var result = new List<MedicationDto>();
        foreach (var m in meds)
        {
            result.Add(await ToDtoAsync(m, ct));
        }

        return result;
    }

    public async Task<List<MedicationDose>> RecentDosesAsync(Guid medicationId, DateTimeOffset around, CancellationToken ct)
    {
        // Wide enough for both the interval (up to 72 h) and the 24-hour limit, on both sides of a back-dated dose.
        var from = around.AddMinutes(-Medication.MaxInterval);
        var to = around.AddMinutes(Medication.MaxInterval);
        return await db.MedicationDoses.AsNoTracking()
            .Where(d => d.MedicationId == medicationId && d.GivenAt >= from && d.GivenAt <= to)
            .ToListAsync(ct);
    }

    public async Task<MedicationDto> ToDtoAsync(Medication m, CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        var recent = await RecentDosesAsync(m.Id, now, ct);
        var last = recent.Where(d => d.GivenAt <= now).MaxBy(d => d.GivenAt);
        var next = m.NextAllowedAt(recent, now);
        return new MedicationDto(m.Id, m.ChildId, m.Name, m.Dose, m.MinIntervalMinutes, m.MaxDosesPerDay, m.RemindNextDose, m.Notes, m.Active,
            last is null ? null : await ToDtoAsync(last, ct),
            recent.Count(d => d.GivenAt > now.AddHours(-24) && d.GivenAt <= now),
            next is { } n && n > now ? n : null);
    }

    public async Task<DoseDto> ToDtoAsync(MedicationDose d, CancellationToken ct)
    {
        var name = d.GivenByUserId is { } uid
            ? await db.Users.AsNoTracking().Where(u => u.Id == uid).Select(u => u.DisplayName).FirstOrDefaultAsync(ct)
            : null;
        return new DoseDto(d.Id, d.MedicationId, d.GivenAt, d.GivenByUserId, name, d.Note, d.OverrodeWarning);
    }

    /// <summary>Tells every adult's open app to reload. Best effort.</summary>
    public async Task AnnounceAsync(Guid familyId, Guid medicationId, CancellationToken ct)
    {
        try
        {
            var adults = await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == familyId).Select(m => m.UserId).ToListAsync(ct);
            await hub.Clients.Groups(adults.Select(ChatHub.UserGroup).ToList()).MedicationChanged(new MedicationEvent(familyId, medicationId));
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Realtime medication event failed");
        }
    }

    /// <summary>Pushes "Ayşe gave Ela Fever syrup at 14:05" to the other adults, so a closed app still prevents a
    /// second dose. Push only (no inbox entry): the medication page is the record.</summary>
    public async Task PushDoseGivenAsync(Medication med, MedicationDose dose, Guid giverId, CancellationToken ct)
    {
        try
        {
            var family = await db.Families.AsNoTracking().FirstAsync(f => f.Id == med.FamilyId, ct);
            var child = await db.Children.AsNoTracking().Where(c => c.Id == med.ChildId).Select(c => c.FirstName).FirstAsync(ct);
            var giver = await db.Users.AsNoTracking().Where(u => u.Id == giverId).Select(u => u.DisplayName).FirstAsync(ct);
            var first = giver.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? giver;
            var others = await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == med.FamilyId && m.UserId != giverId)
                .Join(db.Users.AsNoTracking(), m => m.UserId, u => u.Id, (m, u) => new { u.Id, u.Locale }).ToListAsync(ct);
            var ids = others.Select(o => o.Id).ToList();
            var devices = await db.Devices.AsNoTracking().Where(d => ids.Contains(d.UserId)).ToListAsync(ct);
            var time = FamilyTimeZone.ToFamilyTime(dose.GivenAt, family.TimeZoneId).ToString("HH:mm");
            var invalid = new List<string>();
            foreach (var user in others)
            {
                var tokens = devices.Where(d => d.UserId == user.Id).Select(d => d.Token).ToList();
                if (tokens.Count == 0)
                {
                    continue;
                }

                var (title, body) = MedicationTexts.Given(user.Locale, first, child, med.Name, time);
                var data = new Dictionary<string, string> { ["kind"] = "MedicationGiven", ["familyId"] = med.FamilyId.ToString(), ["medicationId"] = med.Id.ToString() };
                invalid.AddRange(await push.SendAsync(tokens, new PushMessage(title, body, data), ct));
            }

            if (invalid.Count > 0)
            {
                await db.Devices.Where(d => invalid.Contains(d.Token)).ExecuteDeleteAsync(ct);
            }
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Medication push failed");
        }
    }
}

public static class MedicationTexts
{
    public static (string Title, string Body) Given(string locale, string giver, string child, string medication, string time) =>
        Locales.IsTurkish(locale)
            ? ($"{child}: {medication} verildi", $"{giver} verdi · {time}")
            : ($"{child}: {medication} given", $"{giver} gave it at {time}.");

    public static (string Title, string Body) Due(string locale, string child, string medication, string lastTime) =>
        Locales.IsTurkish(locale)
            ? ($"{child}: {medication} zamanı", $"Son doz: {lastTime}. Verdiyseniz uygulamada işaretleyin.")
            : ($"{child}: time for {medication}", $"The last dose was at {lastTime}. Mark it in the app once given.");
}

/// <summary>Every minute: for medications with <see cref="Medication.RemindNextDose"/>, tells the adults when the
/// next dose fits the rule. Once per dose (dedup key), and only within an hour of that time, so an old course
/// that nobody continued does not keep reminding.</summary>
public class MedicationDueJob(HallyDbContext db, NotificationPublisher publisher, MedicationService medications, TimeProvider clock)
{
    public static readonly TimeSpan Window = TimeSpan.FromHours(1);

    public async Task<int> RunAsync(CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        var meds = await db.Medications.AsNoTracking().Where(m => m.Active && m.RemindNextDose).ToListAsync(ct);
        var added = 0;
        foreach (var med in meds)
        {
            var recent = await medications.RecentDosesAsync(med.Id, now, ct);
            var last = recent.Where(d => d.GivenAt <= now).MaxBy(d => d.GivenAt);
            if (last is null || med.NextAllowedAt(recent, now) is not { } due || due > now || now - due > Window)
            {
                continue;
            }

            var family = await db.Families.AsNoTracking().FirstAsync(f => f.Id == med.FamilyId, ct);
            var child = await db.Children.AsNoTracking().Where(c => c.Id == med.ChildId).Select(c => c.FirstName).FirstAsync(ct);
            var adults = await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == med.FamilyId)
                .Join(db.Users.AsNoTracking(), m => m.UserId, u => u.Id, (m, u) => new { u.Id, u.Locale }).ToListAsync(ct);
            var lastTime = FamilyTimeZone.ToFamilyTime(last.GivenAt, family.TimeZoneId).ToString("HH:mm");
            foreach (var adult in adults)
            {
                var (title, body) = MedicationTexts.Due(adult.Locale, child, med.Name, lastTime);
                if (await publisher.AddAsync(adult.Id, med.FamilyId, NotificationKind.MedicationDue, title, body, null, med.Id,
                        $"med:{last.Id:N}:{adult.Id:N}", ct))
                {
                    added++;
                }
            }
        }

        if (added > 0)
        {
            await db.SaveChangesAsync(ct);
            await publisher.FlushPushAsync(ct);
        }

        return added;
    }
}
