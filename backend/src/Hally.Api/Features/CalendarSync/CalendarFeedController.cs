using System.Globalization;
using System.Text;
using Hally.Api.Auth;
using Hally.Api.Common;
using Hally.Api.Features.Events;
using Hally.Domain.Planning;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace Hally.Api.Features.CalendarSync;

public record CalendarFeedStatusDto(bool Active, DateTimeOffset? CreatedAt, DateTimeOffset? LastFetchedAt);

/// <param name="Url">https link for "add calendar from URL" screens.</param>
/// <param name="WebcalUrl">The same link as webcal://, which opens the phone's or computer's calendar app directly.</param>
public record CalendarFeedLinkDto(string Url, string WebcalUrl, DateTimeOffset CreatedAt);

/// <summary>The caller's private iCal subscription link to the family's Hally events. Parents only.</summary>
[ApiController]
[Authorize(Policy = Policies.FamilyMember)]
[Route("api/v1/families/{familyId:guid}/calendar-feed")]
public class CalendarFeedController(HallyDbContext db, IOptions<AppOptions> app, TimeProvider clock) : ControllerBase
{
    [HttpGet]
    public async Task<CalendarFeedStatusDto> Status(Guid familyId, CancellationToken ct)
    {
        var me = User.UserId();
        var feed = await db.CalendarFeeds.AsNoTracking().FirstOrDefaultAsync(f => f.FamilyId == familyId && f.UserId == me, ct);
        return new CalendarFeedStatusDto(feed is not null, feed?.CreatedAt, feed?.LastFetchedAt);
    }

    /// <summary>Makes a new link. Only its hash is kept, so this is the one time the link is returned; an older link stops working.</summary>
    [HttpPost]
    [Idempotent]
    [ProducesResponseType<CalendarFeedLinkDto>(201)]
    public async Task<IActionResult> Create(Guid familyId, CancellationToken ct)
    {
        var me = User.UserId();
        var now = clock.GetUtcNow();
        await db.CalendarFeeds.Where(f => f.FamilyId == familyId && f.UserId == me).ExecuteDeleteAsync(ct);
        var token = Crypto.NewToken();
        var feed = new CalendarFeed(familyId, me, Crypto.Sha256(token), now);
        db.CalendarFeeds.Add(feed);
        await db.SaveChangesAsync(ct);

        var url = $"{app.Value.PublicBaseUrl.TrimEnd('/')}/ics/{token}.ics";
        var webcal = url.StartsWith("https://", StringComparison.OrdinalIgnoreCase) ? "webcal://" + url["https://".Length..]
            : url.StartsWith("http://", StringComparison.OrdinalIgnoreCase) ? "webcal://" + url["http://".Length..] : url;
        return StatusCode(201, new CalendarFeedLinkDto(url, webcal, now));
    }

    [HttpDelete]
    public async Task<IActionResult> Revoke(Guid familyId, CancellationToken ct)
    {
        var me = User.UserId();
        await db.CalendarFeeds.Where(f => f.FamilyId == familyId && f.UserId == me).ExecuteDeleteAsync(ct);
        return NoContent();
    }
}

/// <summary>The feed itself, fetched by Google, iCloud or Outlook without an account. Hally events only (never the
/// shared phone events, which already live in someone's calendar), from 30 days back to a year ahead.</summary>
[ApiController]
[AllowAnonymous]
[ApiExplorerSettings(IgnoreApi = true)]
[Route("ics/{token}.ics")]
public class CalendarFeedFileController(HallyDbContext db, IOptions<AppOptions> app, TimeProvider clock) : ControllerBase
{
    public static readonly TimeSpan Past = TimeSpan.FromDays(30);
    public static readonly TimeSpan Ahead = TimeSpan.FromDays(365);

    [HttpGet]
    public async Task<IActionResult> Get(string token, CancellationToken ct)
    {
        var feed = await db.CalendarFeeds.FirstOrDefaultAsync(f => f.TokenHash == Crypto.Sha256(token), ct);
        // The link dies with the parent's place in the family (left, removed or turned caregiver).
        if (feed is null || !await db.FamilyMembers.AnyAsync(m => m.FamilyId == feed.FamilyId && m.UserId == feed.UserId
                && (m.Role == Domain.Families.FamilyRole.Owner || m.Role == Domain.Families.FamilyRole.Adult), ct))
        {
            return NotFound();
        }

        var now = clock.GetUtcNow();
        feed.Fetched(now);
        await db.SaveChangesAsync(ct);

        var family = await db.Families.AsNoTracking().FirstAsync(f => f.Id == feed.FamilyId, ct);
        var zone = TimeZoneInfo.FindSystemTimeZoneById(family.TimeZoneId);
        var events = await db.EventsInRangeAsync(feed.FamilyId, now - Past, now + Ahead, family.TimeZoneId, ct);
        var children = await db.Children.AsNoTracking().Where(c => c.FamilyId == feed.FamilyId).ToDictionaryAsync(c => c.Id, c => c.FirstName, ct);
        var ics = Ics.Calendar($"{app.Value.Name} · {family.Name}", family.TimeZoneId, events.Select(e => Ics.Event(e, zone, children, now)));

        Response.Headers.CacheControl = "private, max-age=900";
        Response.Headers["X-Robots-Tag"] = "noindex, nofollow";
        Response.Headers["Referrer-Policy"] = "no-referrer";
        return File(Encoding.UTF8.GetBytes(ics), "text/calendar; charset=utf-8", "hally.ics");
    }
}

/// <summary>Minimal RFC 5545 writer: one VEVENT per occurrence (series are expanded, so no RRULE to get wrong).</summary>
public static class Ics
{
    public static string Calendar(string name, string timeZoneId, IEnumerable<string> events)
    {
        var sb = new StringBuilder();
        Line(sb, "BEGIN:VCALENDAR");
        Line(sb, "VERSION:2.0");
        Line(sb, "PRODID:-//Hally//Family calendar//EN");
        Line(sb, "CALSCALE:GREGORIAN");
        Line(sb, "METHOD:PUBLISH");
        Line(sb, "X-WR-CALNAME:" + Escape(name));
        Line(sb, "X-WR-TIMEZONE:" + timeZoneId);
        Line(sb, "REFRESH-INTERVAL;VALUE=DURATION:PT1H");
        Line(sb, "X-PUBLISHED-TTL:PT1H");
        foreach (var e in events)
        {
            sb.Append(e);
        }

        Line(sb, "END:VCALENDAR");
        return sb.ToString();
    }

    public static string Event(CalendarEvent e, TimeZoneInfo zone, IReadOnlyDictionary<Guid, string> children, DateTimeOffset now)
    {
        var sb = new StringBuilder();
        var names = e.ChildIds.Select(id => children.GetValueOrDefault(id)).OfType<string>().ToList();
        var title = names.Count == 0 ? e.Title : $"{e.Title} ({string.Join(", ", names)})";
        Line(sb, "BEGIN:VEVENT");
        Line(sb, $"UID:{e.Id:N}-{e.StartsAt.UtcDateTime:yyyyMMdd'T'HHmm}@hally.app");
        Line(sb, "DTSTAMP:" + Utc(now));
        if (e.AllDay)
        {
            var first = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(e.StartsAt, zone).DateTime);
            var lastExclusive = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(e.EffectiveEnd, zone).DateTime);
            if (lastExclusive <= first)
            {
                lastExclusive = first.AddDays(1);
            }

            Line(sb, "DTSTART;VALUE=DATE:" + first.ToString("yyyyMMdd", CultureInfo.InvariantCulture));
            Line(sb, "DTEND;VALUE=DATE:" + lastExclusive.ToString("yyyyMMdd", CultureInfo.InvariantCulture));
        }
        else
        {
            Line(sb, "DTSTART:" + Utc(e.StartsAt));
            Line(sb, "DTEND:" + Utc(e.EffectiveEnd));
        }

        Line(sb, "SUMMARY:" + Escape(title));
        if (e.Location is { } location)
        {
            Line(sb, "LOCATION:" + Escape(location));
        }

        Line(sb, "END:VEVENT");
        return sb.ToString();
    }

    private static string Utc(DateTimeOffset t) => t.UtcDateTime.ToString("yyyyMMdd'T'HHmmss'Z'", CultureInfo.InvariantCulture);

    public static string Escape(string text) =>
        text.Replace("\\", "\\\\").Replace(";", "\\;").Replace(",", "\\,").Replace("\r\n", "\\n").Replace("\n", "\\n").Replace("\r", "\\n");

    /// <summary>Writes a content line, folded at 75 octets without splitting a UTF-8 character.</summary>
    private static void Line(StringBuilder sb, string line)
    {
        var bytes = 0;
        var start = 0;
        for (var i = 0; i < line.Length; i += char.IsHighSurrogate(line[i]) && i + 1 < line.Length ? 2 : 1)
        {
            var len = Encoding.UTF8.GetByteCount(line.AsSpan(i, char.IsHighSurrogate(line[i]) && i + 1 < line.Length ? 2 : 1));
            if (bytes + len > 75)
            {
                sb.Append(line, start, i - start).Append("\r\n ");
                start = i;
                bytes = 1; // the leading space of the continuation line
            }

            bytes += len;
        }

        sb.Append(line, start, line.Length - start).Append("\r\n");
    }
}
