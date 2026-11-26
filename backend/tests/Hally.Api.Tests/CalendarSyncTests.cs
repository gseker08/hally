using System.Net;
using System.Net.Http.Json;
using FluentAssertions;
using Hally.Api.Features.CalendarSync;
using Microsoft.AspNetCore.Mvc.Testing;

namespace Hally.Api.Tests;

public record ExternalEventBody(Guid Id, Guid OwnerUserId, string OwnerName, bool Mine, string Provider, string CalendarName, string? Title, bool BusyOnly,
    DateTimeOffset StartsAt, DateTimeOffset EndsAt, bool AllDay, string? ColorHex);
public record SyncResultBody(int Shared, int Removed);
public record FeedLinkBody(string Url, string WebcalUrl, DateTimeOffset CreatedAt);
public record FeedStatusBody(bool Active, DateTimeOffset? CreatedAt, DateTimeOffset? LastFetchedAt);

[Collection(ApiCollection.Name)]
public class CalendarSyncTests(HallyApiFactory api)
{
    private static string Email() => $"{Guid.NewGuid():N}@example.com";

    private async Task<(HttpClient Ayse, HttpClient Mehmet, HttpClient Zeynep, string F, Guid FamilyId)> FamilyAsync()
    {
        var ayse = await api.SignInAsync(Email(), "Ayşe Yılmaz");
        var family = (await (await ayse.PostIdempotentAsync("/api/v1/families", new { name = "Yılmaz", timeZoneId = "Europe/Istanbul" })).Content.ReadFromJsonAsync<FamilyBody>())!;
        var f = $"/api/v1/families/{family.Id}";
        var invite = (await (await ayse.PostIdempotentAsync($"{f}/invitations", null)).Content.ReadFromJsonAsync<InvitationBody>())!;
        var mehmet = await api.SignInAsync(Email(), "Mehmet Yılmaz");
        await mehmet.PostIdempotentAsync($"/api/v1/invitations/{invite.Token}/accept", null);
        var careInvite = (await (await ayse.PostIdempotentAsync($"{f}/invitations", new { role = "caregiver" })).Content.ReadFromJsonAsync<RoleInvitationBody>())!;
        var zeynep = await api.SignInAsync(Email(), "Zeynep");
        await zeynep.PostIdempotentAsync($"/api/v1/invitations/{careInvite.Token}/accept", null);
        return (ayse, mehmet, zeynep, f, family.Id);
    }

    private static object Ev(string key, string? title, DateTimeOffset start, int hours = 1, bool busy = false, string provider = "Google", string calendar = "Kişisel") =>
        new { sourceKey = key, provider, calendarName = calendar, title, busyOnly = busy, startsAt = start, endsAt = start.AddHours(hours), allDay = false, colorHex = "#5f7f5a" };

    private DateTimeOffset Tomorrow(int hour) => new DateTimeOffset(api.Clock.GetUtcNow().UtcDateTime.Date.AddDays(1).AddHours(hour), TimeSpan.Zero);

    private static string Range(DateTimeOffset from, int days) =>
        $"from={Uri.EscapeDataString(from.ToString("O"))}&to={Uri.EscapeDataString(from.AddDays(days).ToString("O"))}";

    [Fact]
    public async Task A_parent_shares_phone_events_and_the_other_parent_sees_them_read_only()
    {
        var (ayse, mehmet, zeynep, f, _) = await FamilyAsync();
        var day = Tomorrow(0);

        var res = await ayse.PutAsJsonAsync($"{f}/external-events", new
        {
            events = new[]
        {
            Ev("cal1|a|1", "Diş hekimi", day.AddHours(14)),
            Ev("cal2|b|1", "Bütçe toplantısı", day.AddHours(7), busy: true, provider: "Outlook", calendar: "İş"),
        }
        });
        res.StatusCode.Should().Be(HttpStatusCode.OK);
        (await res.Content.ReadFromJsonAsync<SyncResultBody>())!.Should().Be(new SyncResultBody(2, 0));

        var seen = (await mehmet.GetFromJsonAsync<List<ExternalEventBody>>($"{f}/external-events?{Range(day, 1)}"))!;
        seen.Select(e => e.Title).Should().Equal(null, "Diş hekimi");
        seen[0].Should().Match<ExternalEventBody>(e => e.BusyOnly && e.Provider == "Outlook" && e.OwnerName == "Ayşe" && !e.Mine);
        seen[1].ColorHex.Should().Be("#5F7F5A");
        (await ayse.GetFromJsonAsync<List<ExternalEventBody>>($"{f}/external-events?{Range(day, 1)}"))!.Should().OnlyContain(e => e.Mine);

        (await zeynep.GetAsync($"{f}/external-events?{Range(day, 1)}")).StatusCode.Should().Be(HttpStatusCode.Forbidden, "caregivers don't see parents' calendars");
        (await zeynep.PutAsJsonAsync($"{f}/external-events", new { events = Array.Empty<object>() })).StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }

    [Fact]
    public async Task Each_sync_replaces_the_set_and_never_touches_the_other_parent()
    {
        var (ayse, mehmet, _, f, _) = await FamilyAsync();
        var day = Tomorrow(0);
        await ayse.PutAsJsonAsync($"{f}/external-events", new { events = new[] { Ev("a", "Yoga", day.AddHours(8)), Ev("b", "Kuaför", day.AddHours(10)) } });
        await mehmet.PutAsJsonAsync($"{f}/external-events", new { events = new[] { Ev("a", "Futbol", day.AddHours(18)) } });

        var res = await ayse.PutAsJsonAsync($"{f}/external-events", new { events = new[] { Ev("a", "Yoga (ertelendi)", day.AddHours(9)) } });
        (await res.Content.ReadFromJsonAsync<SyncResultBody>())!.Should().Be(new SyncResultBody(1, 1));
        var all = (await ayse.GetFromJsonAsync<List<ExternalEventBody>>($"{f}/external-events?{Range(day, 1)}"))!;
        all.Select(e => e.Title).Should().Equal("Yoga (ertelendi)", "Futbol");
        all[0].StartsAt.Should().Be(day.AddHours(9));

        (await ayse.DeleteAsync($"{f}/external-events")).StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await mehmet.GetFromJsonAsync<List<ExternalEventBody>>($"{f}/external-events?{Range(day, 1)}"))!.Select(e => e.OwnerName).Should().Equal("Mehmet");
    }

    [Fact]
    public async Task Bad_input_is_refused_and_leaving_the_family_takes_the_events_along()
    {
        var (ayse, mehmet, _, f, familyId) = await FamilyAsync();
        var day = Tomorrow(0);
        var bad = new { sourceKey = "x", provider = "Google", calendarName = "K", title = "T", busyOnly = false, startsAt = day.AddHours(3), endsAt = day.AddHours(2), allDay = false };
        (await ayse.PutAsJsonAsync($"{f}/external-events", new { events = new[] { bad } })).StatusCode.Should().Be(HttpStatusCode.BadRequest);
        var tooMany = Enumerable.Range(0, ExternalEventsController.MaxEvents + 1).Select(i => Ev($"k{i}", "T", day)).ToArray();
        (await ayse.PutAsJsonAsync($"{f}/external-events", new { events = tooMany })).StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await ayse.GetAsync($"{f}/external-events?{Range(day, 500)}")).StatusCode.Should().Be(HttpStatusCode.BadRequest);

        await mehmet.PutAsJsonAsync($"{f}/external-events", new { events = new[] { Ev("a", "Futbol", day.AddHours(18)) } });
        await mehmet.PostAsync($"/api/v1/families/{familyId}/leave", null);
        (await ayse.GetFromJsonAsync<List<ExternalEventBody>>($"{f}/external-events?{Range(day, 1)}"))!.Should().BeEmpty();
    }

    [Fact]
    public async Task The_subscription_link_serves_hally_events_as_ical_until_it_is_replaced()
    {
        var (ayse, mehmet, zeynep, f, _) = await FamilyAsync();
        var child = (await (await ayse.PostIdempotentAsync($"{f}/children", new { firstName = "Ela" })).Content.ReadFromJsonAsync<ChildBody>())!;
        var day = Tomorrow(0);
        await ayse.PostIdempotentAsync($"{f}/events", new { title = "Piyano; dersi, ilk", startsAt = day.AddHours(13), allDay = false, childIds = new[] { child.Id } });
        await ayse.PostIdempotentAsync($"{f}/events", new { title = "Okul gezisi", startsAt = day.AddDays(2), allDay = true });
        await ayse.PostIdempotentAsync($"{f}/events", new { title = "Yüzme", startsAt = day.AddHours(8), allDay = false, repeat = "Weekly" });
        await mehmet.PutAsJsonAsync($"{f}/external-events", new { events = new[] { Ev("a", "Mehmet'in toplantısı", day.AddHours(9)) } });

        (await ayse.GetFromJsonAsync<FeedStatusBody>($"{f}/calendar-feed"))!.Active.Should().BeFalse();
        var res = await ayse.PostIdempotentAsync($"{f}/calendar-feed", null);
        res.StatusCode.Should().Be(HttpStatusCode.Created);
        var link = (await res.Content.ReadFromJsonAsync<FeedLinkBody>())!;
        link.WebcalUrl.Should().StartWith("webcal://").And.EndWith(".ics");

        var anon = api.CreateClient(new WebApplicationFactoryClientOptions { AllowAutoRedirect = false });
        var path = new Uri(link.Url).AbsolutePath;
        var ics = await anon.GetAsync(path);
        ics.StatusCode.Should().Be(HttpStatusCode.OK);
        ics.Content.Headers.ContentType!.MediaType.Should().Be("text/calendar");
        var body = await ics.Content.ReadAsStringAsync();
        body.Should().StartWith("BEGIN:VCALENDAR\r\n").And.EndWith("END:VCALENDAR\r\n");
        body.Should().Contain(@"SUMMARY:Piyano\; dersi\, ilk (Ela)").And.Contain("X-WR-CALNAME:Hally · Yılmaz");
        body.Should().Contain("DTSTART;VALUE=DATE:").And.Contain("SUMMARY:Okul gezisi");
        System.Text.RegularExpressions.Regex.Matches(body, "SUMMARY:Yüzme").Count.Should().BeGreaterThan(40, "a weekly series is expanded for a year");
        body.Should().NotContain("Mehmet'in toplantısı", "shared phone events are not echoed back out");
        body.Split("\r\n").Should().OnlyContain(l => System.Text.Encoding.UTF8.GetByteCount(l) <= 75);
        (await ayse.GetFromJsonAsync<FeedStatusBody>($"{f}/calendar-feed"))!.LastFetchedAt.Should().NotBeNull();

        (await zeynep.PostIdempotentAsync($"{f}/calendar-feed", null)).StatusCode.Should().Be(HttpStatusCode.Forbidden);

        var second = (await (await ayse.PostIdempotentAsync($"{f}/calendar-feed", null)).Content.ReadFromJsonAsync<FeedLinkBody>())!;
        (await anon.GetAsync(path)).StatusCode.Should().Be(HttpStatusCode.NotFound, "a new link replaces the old one");
        (await anon.GetAsync(new Uri(second.Url).AbsolutePath)).StatusCode.Should().Be(HttpStatusCode.OK);
        (await ayse.DeleteAsync($"{f}/calendar-feed")).StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await anon.GetAsync(new Uri(second.Url).AbsolutePath)).StatusCode.Should().Be(HttpStatusCode.NotFound);
    }

    [Fact]
    public async Task The_link_stops_when_its_parent_leaves()
    {
        var (_, mehmet, _, f, familyId) = await FamilyAsync();
        var link = (await (await mehmet.PostIdempotentAsync($"{f}/calendar-feed", null)).Content.ReadFromJsonAsync<FeedLinkBody>())!;
        var anon = api.CreateClient();
        (await anon.GetAsync(new Uri(link.Url).AbsolutePath)).StatusCode.Should().Be(HttpStatusCode.OK);
        await mehmet.PostAsync($"/api/v1/families/{familyId}/leave", null);
        (await anon.GetAsync(new Uri(link.Url).AbsolutePath)).StatusCode.Should().Be(HttpStatusCode.NotFound);
    }
}
