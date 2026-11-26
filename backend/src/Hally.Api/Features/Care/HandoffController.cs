using System.Text.Json;
using Hally.Api.Auth;
using Hally.Api.Common;
using Hally.Api.Features.Messages;
using Hally.Api.Features.Notifications;
using Hally.Domain.Care;
using Hally.Domain.Common;
using Hally.Domain.Families;
using Hally.Domain.Feeding;
using Hally.Domain.Notifications;
using Hally.Domain.Sleep;
using Hally.Domain.Users;
using Hally.Infrastructure.Persistence;
using Hally.Infrastructure.Storage;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.Care;

/// <summary>What was logged for the child on the day. Times are family-local "HH:mm".</summary>
/// <param name="Foods">Solid food names in the order they were logged.</param>
/// <param name="Sleeps">"13:10–14:35" per sleep that started on the day ("13:10–" while still asleep).</param>
/// <param name="Doses">"Şurup 5 ml · 12:00" per dose given on the day.</param>
public record HandoffSummaryDto(
    int Feeds,
    int BottleMl,
    int BreastMinutes,
    int Solids,
    IReadOnlyList<string> Foods,
    int SleepMinutes,
    IReadOnlyList<string> Sleeps,
    IReadOnlyList<string> Doses,
    int ScreenMinutes)
{
    public static readonly HandoffSummaryDto Empty = new(0, 0, 0, 0, [], 0, [], [], 0);
}

public record HandoffReportDto(
    Guid Id,
    Guid ChildId,
    string ChildName,
    Guid ByUserId,
    string ByName,
    DateOnly Day,
    HandoffSummaryDto Summary,
    IReadOnlyList<string> Incidents,
    string? Note,
    bool HasPhoto,
    DateTimeOffset SentAt,
    DateTimeOffset? ThankedAt);

/// <summary>The live summary for the "Günü bitir" screen, and the report already sent today (if any).</summary>
public record HandoffDraftDto(DateOnly Day, HandoffSummaryDto Summary, HandoffReportDto? Sent);

/// <param name="Incidents">"Fall", "Fever", "Other"; empty for a calm day.</param>
public record SendHandoffRequest(IReadOnlyList<string>? Incidents, string? Note);

/// <summary>
/// Caregiver handoff ("Günü bitir"): at the end of the day the caregiver sends parents one report per child. The summary
/// is built from what was logged in Hally that day, so the caregiver only adds incidents, a note and maybe a photo.
/// Parents get a push and a card on Today, and can say thanks. Reports stay on the child's page.
/// </summary>
[ApiController]
[Authorize(Policy = Policies.FamilyMember)]
[Route("api/v1/families/{familyId:guid}")]
public class HandoffController(
    HallyDbContext db,
    IDocumentStore store,
    NotificationPublisher publisher,
    TimeProvider clock,
    ILogger<HandoffController> logger) : ControllerBase
{
    private const long MaxPhotoBytes = 10 * 1024 * 1024;
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    [CaregiverAllowed]
    [HttpGet("children/{childId:guid}/handoff/draft")]
    public async Task<HandoffDraftDto> Draft(Guid familyId, Guid childId, CancellationToken ct)
    {
        var (tz, today) = await Today(familyId, ct);
        await EnsureChild(familyId, childId, ct);
        var summary = await SummaryAsync(familyId, childId, today, tz, ct);
        var me = User.UserId();
        var sent = await db.HandoffReports.AsNoTracking().FirstOrDefaultAsync(r => r.ChildId == childId && r.Day == today && r.ByUserId == me, ct);
        return new HandoffDraftDto(today, summary, sent is null ? null : (await ToDtos(familyId, [sent], ct))[0]);
    }

    /// <summary>Sends (or re-sends) today's report for the child and tells the parents.</summary>
    [CaregiverAllowed]
    [HttpPost("children/{childId:guid}/handoffs")]
    public async Task<HandoffReportDto> Send(Guid familyId, Guid childId, SendHandoffRequest request, CancellationToken ct)
    {
        var (tz, today) = await Today(familyId, ct);
        await EnsureChild(familyId, childId, ct);
        var incidents = new List<HandoffIncident>();
        foreach (var raw in request.Incidents ?? [])
        {
            incidents.Add(Enum.TryParse<HandoffIncident>(raw, true, out var i) && Enum.IsDefined(i)
                ? i
                : throw new DomainException("handoff.incident_invalid", "Incidents are Fall, Fever or Other."));
        }

        var me = User.UserId();
        var now = clock.GetUtcNow();
        var report = await db.HandoffReports.FirstOrDefaultAsync(r => r.ChildId == childId && r.Day == today && r.ByUserId == me, ct);
        var again = report is not null;
        if (report is null)
        {
            report = new HandoffReport(familyId, childId, me, today, now);
            db.HandoffReports.Add(report);
        }

        var summary = await SummaryAsync(familyId, childId, today, tz, ct);
        report.Fill(JsonSerializer.Serialize(summary, Json), incidents, request.Note, now);
        await db.SaveChangesAsync(ct);
        await TellParents(familyId, report, again, ct);
        return (await ToDtos(familyId, [report], ct))[0];
    }

    /// <summary>Adds or replaces the report's photo (JPEG, PNG, WebP or HEIC up to 10 MB, stored encrypted).</summary>
    [CaregiverAllowed]
    [HttpPost("handoffs/{reportId:guid}/photo")]
    [RequestSizeLimit(MaxPhotoBytes + 64 * 1024)]
    public async Task<HandoffReportDto> Photo(Guid familyId, Guid reportId, IFormFile? file, CancellationToken ct)
    {
        var report = await db.HandoffReports.FirstOrDefaultAsync(r => r.Id == reportId && r.FamilyId == familyId && r.ByUserId == User.UserId(), ct)
                     ?? throw new NotFoundException("handoff.not_found", "Report not found.");
        if (file is null || file.Length == 0 || file.Length > MaxPhotoBytes)
        {
            throw new DomainException("handoff.photo_invalid", "Send a JPEG, PNG, WebP or HEIC photo up to 10 MB.");
        }

        using var ms = new MemoryStream();
        await file.CopyToAsync(ms, ct);
        var bytes = ms.ToArray();
        var contentType = PhotoFormat.Detect(bytes) ?? throw new DomainException("handoff.photo_invalid", "Send a JPEG, PNG, WebP or HEIC photo up to 10 MB.");
        var key = await store.SaveAsync(familyId, bytes, ct);
        var old = report.SetPhoto(key, contentType);
        await db.SaveChangesAsync(ct);
        if (old is not null)
        {
            await store.DeleteAsync(old, CancellationToken.None);
        }

        return (await ToDtos(familyId, [report], ct))[0];
    }

    [CaregiverAllowed]
    [HttpGet("handoffs/{reportId:guid}/photo")]
    public async Task<IActionResult> GetPhoto(Guid familyId, Guid reportId, CancellationToken ct)
    {
        var report = await Visible(familyId).FirstOrDefaultAsync(r => r.Id == reportId, ct);
        if (report?.PhotoKey is null || await store.ReadAsync(report.PhotoKey, ct) is not { } bytes)
        {
            throw new NotFoundException("handoff.photo_not_found", "Photo not found.");
        }

        Response.Headers.CacheControl = "private, max-age=3600";
        Response.Headers.XContentTypeOptions = "nosniff";
        return File(bytes, report.PhotoContentType ?? "image/jpeg");
    }

    /// <summary>
    /// Reports, newest first. <c>day</c> limits to one family-local day (Today uses it); <c>childId</c> to one child.
    /// Parents see every report; a caregiver sees their own.
    /// </summary>
    [CaregiverAllowed]
    [HttpGet("handoffs")]
    public async Task<List<HandoffReportDto>> List(Guid familyId, [FromQuery] Guid? childId, [FromQuery] DateOnly? day, [FromQuery] int limit = 30,
        CancellationToken ct = default)
    {
        var q = Visible(familyId);
        if (childId is { } c)
        {
            q = q.Where(r => r.ChildId == c);
        }

        if (day is { } d)
        {
            q = q.Where(r => r.Day == d);
        }

        var reports = await q.OrderByDescending(r => r.SentAt).Take(Math.Clamp(limit, 1, 100)).ToListAsync(ct);
        return await ToDtos(familyId, reports, ct);
    }

    /// <summary>A parent's "Teşekkürler 💛": hides the card on Today and tells the caregiver.</summary>
    [HttpPost("handoffs/{reportId:guid}/thanks")]
    public async Task<HandoffReportDto> Thanks(Guid familyId, Guid reportId, CancellationToken ct)
    {
        var report = await db.HandoffReports.FirstOrDefaultAsync(r => r.Id == reportId && r.FamilyId == familyId, ct)
                     ?? throw new NotFoundException("handoff.not_found", "Report not found.");
        var me = User.UserId();
        var first = report.ThankedAt is null;
        report.Thank(me, clock.GetUtcNow());
        await db.SaveChangesAsync(ct);
        if (first)
        {
            await Notify(familyId, [report.ByUserId], NotificationKind.HandoffThanks, report,
                async (tr, _) =>
                {
                    var who = await FirstName(me, ct);
                    return tr ? ($"{who} teşekkür etti 💛", "Günün raporu için teşekkürler.") : ($"{who} said thanks 💛", "Thanks for today's report.");
                }, $"handoff-thanks:{report.Id:N}", ct);
        }

        return (await ToDtos(familyId, [report], ct))[0];
    }

    private IQueryable<HandoffReport> Visible(Guid familyId)
    {
        var access = HttpContext.Access();
        var q = db.HandoffReports.AsNoTracking().Where(r => r.FamilyId == familyId);
        if (!access.IsParent)
        {
            var me = User.UserId();
            q = q.Where(r => r.ByUserId == me);
        }

        return q;
    }

    /// <summary>Builds the day's summary from the child's logs.</summary>
    private async Task<HandoffSummaryDto> SummaryAsync(Guid familyId, Guid childId, DateOnly day, string tz, CancellationToken ct)
    {
        var start = FamilyTimeZone.StartOfDay(day, tz);
        var end = FamilyTimeZone.StartOfDay(day.AddDays(1), tz);
        var now = clock.GetUtcNow();
        string Hm(DateTimeOffset t) => FamilyTimeZone.ToFamilyTime(t, tz).ToString("HH:mm");

        var feeds = await db.FeedingEntries.AsNoTracking().Where(f => f.ChildId == childId && f.At >= start && f.At < end).OrderBy(f => f.At).ToListAsync(ct);
        var sleeps = await db.SleepEntries.AsNoTracking().Where(s => s.ChildId == childId && s.StartedAt >= start && s.StartedAt < end).OrderBy(s => s.StartedAt).ToListAsync(ct);
        var doses = await db.MedicationDoses.AsNoTracking().Where(d => d.ChildId == childId && d.GivenAt >= start && d.GivenAt < end)
            .Join(db.Medications.AsNoTracking(), d => d.MedicationId, m => m.Id, (d, m) => new { d.GivenAt, m.Name, m.Dose })
            .OrderBy(d => d.GivenAt).ToListAsync(ct);
        var screen = await db.ScreenTimeSessions.AsNoTracking()
            .Where(s => s.ChildId == childId && s.StartedAt < end && (s.EndedAt == null || s.EndedAt > start)).ToListAsync(ct);
        var timerMinutes = (int)Math.Round(screen.Aggregate(TimeSpan.Zero, (sum, s) => sum + s.Within(start, end, now)).TotalMinutes);
        // A paired child phone measures screen time itself; prefer it when it saw more.
        var deviceSeconds = await db.ScreenUsages.AsNoTracking().Where(u => u.ChildId == childId && u.Day == day).Select(u => (int?)u.Seconds).FirstOrDefaultAsync(ct) ?? 0;

        return new HandoffSummaryDto(
            feeds.Count,
            feeds.Where(f => f.Kind == FeedingKind.Bottle).Sum(f => f.AmountMl ?? 0),
            feeds.Where(f => f.Kind == FeedingKind.Breast).Sum(f => f.Minutes ?? 0),
            feeds.Count(f => f.Kind == FeedingKind.Solid),
            feeds.Where(f => f.Food is not null).Select(f => f.Food!).ToList(),
            (int)Math.Round(sleeps.Aggregate(TimeSpan.Zero, (sum, s) => sum + s.Duration(now)).TotalMinutes),
            sleeps.Select(s => $"{Hm(s.StartedAt)}–{(s.EndedAt is { } e ? Hm(e) : "")}").ToList(),
            doses.Select(d => $"{d.Name}{(d.Dose is null ? "" : " " + d.Dose)} · {Hm(d.GivenAt)}").ToList(),
            Math.Max(timerMinutes, deviceSeconds / 60));
    }

    private async Task<List<HandoffReportDto>> ToDtos(Guid familyId, IReadOnlyList<HandoffReport> reports, CancellationToken ct)
    {
        var childIds = reports.Select(r => r.ChildId).Distinct().ToList();
        var userIds = reports.Select(r => r.ByUserId).Distinct().ToList();
        var children = await db.Children.AsNoTracking().Where(c => childIds.Contains(c.Id)).ToDictionaryAsync(c => c.Id, c => c.FirstName, ct);
        var users = await db.Users.AsNoTracking().Where(u => userIds.Contains(u.Id)).ToDictionaryAsync(u => u.Id, u => u.DisplayName, ct);
        return reports.Select(r => new HandoffReportDto(r.Id, r.ChildId, children.GetValueOrDefault(r.ChildId, ""), r.ByUserId,
            users.GetValueOrDefault(r.ByUserId, ""), r.Day, JsonSerializer.Deserialize<HandoffSummaryDto>(r.SummaryJson, Json) ?? HandoffSummaryDto.Empty,
            r.Incidents.Select(i => i.ToString()).ToList(), r.Note, r.PhotoKey is not null, r.SentAt, r.ThankedAt)).ToList();
    }

    private async Task TellParents(Guid familyId, HandoffReport report, bool again, CancellationToken ct)
    {
        var parents = await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == familyId && m.Role != FamilyRole.Caregiver && m.UserId != report.ByUserId)
            .Select(m => m.UserId).ToListAsync(ct);
        var child = await db.Children.AsNoTracking().Where(c => c.Id == report.ChildId).Select(c => c.FirstName).FirstAsync(ct);
        var who = await FirstName(report.ByUserId, ct);
        await Notify(familyId, parents, NotificationKind.HandoffReport, report, (tr, _) => Task.FromResult(HandoffTexts.Sent(tr, who, child, report.Incidents, again)),
            $"handoff:{report.Id:N}:{report.SentAt.ToUnixTimeSeconds()}", ct);
    }

    /// <summary>Inbox entry + push per recipient. Best effort: the report is saved either way.</summary>
    private async Task Notify(Guid familyId, IReadOnlyList<Guid> recipients, NotificationKind kind, HandoffReport report,
        Func<bool, Guid, Task<(string Title, string Body)>> text, string dedup, CancellationToken ct)
    {
        try
        {
            var locales = await db.Users.AsNoTracking().Where(u => recipients.Contains(u.Id)).Select(u => new { u.Id, u.Locale }).ToListAsync(ct);
            var added = false;
            foreach (var r in locales)
            {
                var (title, body) = await text(Locales.IsTurkish(r.Locale), r.Id);
                added |= await publisher.AddAsync(r.Id, familyId, kind, title, body, null, report.Id, $"{dedup}:{r.Id:N}", ct);
            }

            if (added)
            {
                await db.SaveChangesAsync(ct);
                await publisher.FlushPushAsync(ct);
            }
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Handoff notification failed");
        }
    }

    private async Task<string> FirstName(Guid userId, CancellationToken ct)
    {
        var name = await db.Users.AsNoTracking().Where(u => u.Id == userId).Select(u => u.DisplayName).FirstOrDefaultAsync(ct) ?? "";
        return name.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? name;
    }

    private async Task EnsureChild(Guid familyId, Guid childId, CancellationToken ct)
    {
        if (!await db.Children.AnyAsync(c => c.Id == childId && c.FamilyId == familyId, ct))
        {
            throw new NotFoundException("child.not_found", "Child not found.");
        }
    }

    private async Task<(string Tz, DateOnly Today)> Today(Guid familyId, CancellationToken ct)
    {
        var tz = await db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.TimeZoneId).FirstAsync(ct);
        return (tz, FamilyTimeZone.LocalDate(clock.GetUtcNow(), tz));
    }
}

public static class HandoffTexts
{
    public static (string Title, string Body) Sent(bool turkish, string who, string child, IReadOnlyList<HandoffIncident> incidents, bool again)
    {
        if (turkish)
        {
            var title = again ? $"{who} günün raporunu güncelledi" : $"{who} günü bitirdi";
            var body = incidents.Count == 0
                ? $"{child} için günün özeti hazır."
                : $"{child} · Olay: {string.Join(", ", incidents.Select(i => i switch { HandoffIncident.Fall => "küçük düşme", HandoffIncident.Fever => "ateş", _ => "diğer" }))}";
            return (title, body);
        }

        return (again ? $"{who} updated the day's report" : $"{who} finished the day",
            incidents.Count == 0
                ? $"{child}'s summary is ready."
                : $"{child} · Incident: {string.Join(", ", incidents.Select(i => i switch { HandoffIncident.Fall => "small fall", HandoffIncident.Fever => "fever", _ => "other" }))}");
    }
}
