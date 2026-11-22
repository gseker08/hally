using System.Net;
using System.Net.Http.Json;
using FluentAssertions;
using Hally.Domain.Common;
using Hally.Domain.Planning;

namespace Hally.Api.Tests;

public record RepeatingEventBody(Guid Id, string Title, DateTimeOffset StartsAt, DateTimeOffset? EndsAt, string Repeat, string? RepeatUntil, DateTimeOffset SeriesStartsAt);

public class RecurringEventDomainTests
{
    private static readonly TimeZoneInfo Istanbul = TimeZoneInfo.FindSystemTimeZoneById("Europe/Istanbul");
    private static readonly TimeZoneInfo London = TimeZoneInfo.FindSystemTimeZoneById("Europe/London");

    private static CalendarEvent Swimming(DateTimeOffset start, EventRepeat repeat, DateOnly? until = null)
    {
        var e = new CalendarEvent(Guid.NewGuid(), Guid.NewGuid(), "Yüzme", start, start.AddHours(1), false, null, null);
        e.SetRepeat(repeat, until);
        return e;
    }

    [Fact]
    public void Weekly_series_yields_each_week_in_the_window_with_the_same_local_time()
    {
        // Saturday 2026-11-28 11:30 Istanbul = 08:30 UTC.
        var evt = Swimming(new DateTimeOffset(2026, 11, 28, 8, 30, 0, TimeSpan.Zero), EventRepeat.Weekly);

        var dec = evt.OccurrencesOverlapping(new DateTimeOffset(2026, 12, 1, 0, 0, 0, TimeSpan.Zero), new DateTimeOffset(2027, 1, 1, 0, 0, 0, TimeSpan.Zero), Istanbul).ToList();

        dec.Select(o => o.StartsAt.UtcDateTime.Day).Should().Equal(5, 12, 19, 26);
        dec.Should().OnlyContain(o => o.Id == evt.Id && o.SeriesStartsAt == evt.StartsAt && o.EndsAt == o.StartsAt.AddHours(1));
        evt.StartsAt.Should().Be(new DateTimeOffset(2026, 11, 28, 8, 30, 0, TimeSpan.Zero), "the stored series is not modified");
    }

    [Fact]
    public void Series_starts_at_its_first_occurrence_and_stops_after_until()
    {
        var evt = Swimming(new DateTimeOffset(2026, 11, 28, 8, 30, 0, TimeSpan.Zero), EventRepeat.Weekly, until: new DateOnly(2026, 12, 12));

        var all = evt.OccurrencesOverlapping(new DateTimeOffset(2026, 11, 1, 0, 0, 0, TimeSpan.Zero), new DateTimeOffset(2027, 2, 1, 0, 0, 0, TimeSpan.Zero), Istanbul).ToList();

        all.Select(o => DateOnly.FromDateTime(o.StartsAt.UtcDateTime)).Should().Equal(new DateOnly(2026, 11, 28), new DateOnly(2026, 12, 5), new DateOnly(2026, 12, 12));
        all[0].Should().BeSameAs(evt);
    }

    [Fact]
    public void Daily_and_monthly_series_expand_far_from_their_start()
    {
        var daily = Swimming(new DateTimeOffset(2026, 1, 1, 6, 0, 0, TimeSpan.Zero), EventRepeat.Daily);
        daily.OccurrencesOverlapping(new DateTimeOffset(2026, 11, 28, 0, 0, 0, TimeSpan.Zero), new DateTimeOffset(2026, 11, 30, 0, 0, 0, TimeSpan.Zero), Istanbul)
            .Should().HaveCount(2);

        var monthly = Swimming(new DateTimeOffset(2026, 1, 15, 6, 0, 0, TimeSpan.Zero), EventRepeat.Monthly);
        monthly.OccurrencesOverlapping(new DateTimeOffset(2026, 11, 1, 0, 0, 0, TimeSpan.Zero), new DateTimeOffset(2027, 1, 1, 0, 0, 0, TimeSpan.Zero), Istanbul)
            .Select(o => o.StartsAt.UtcDateTime).Should().Equal(new DateTime(2026, 11, 15, 6, 0, 0), new DateTime(2026, 12, 15, 6, 0, 0));
    }

    [Fact]
    public void Weekly_series_keeps_wall_clock_time_across_dst()
    {
        // Saturday 2026-10-17 11:30 London (BST, UTC+1) = 10:30 UTC; after 25 Oct it is GMT, so 11:30 = 11:30 UTC.
        var evt = Swimming(new DateTimeOffset(2026, 10, 17, 10, 30, 0, TimeSpan.Zero), EventRepeat.Weekly);

        var after = evt.OccurrencesOverlapping(new DateTimeOffset(2026, 10, 30, 0, 0, 0, TimeSpan.Zero), new DateTimeOffset(2026, 11, 2, 0, 0, 0, TimeSpan.Zero), London).Single();

        after.StartsAt.Should().Be(new DateTimeOffset(2026, 10, 31, 11, 30, 0, TimeSpan.Zero));
    }

    [Fact]
    public void Until_before_start_is_rejected()
    {
        var evt = Swimming(new DateTimeOffset(2026, 11, 28, 8, 30, 0, TimeSpan.Zero), EventRepeat.None);
        evt.Invoking(e => e.SetRepeat(EventRepeat.Weekly, new DateOnly(2026, 11, 1))).Should().Throw<DomainException>()
            .Which.Code.Should().Be("event.repeat_until_before_start");
    }
}

[Collection(ApiCollection.Name)]
public class RecurringEventApiTests(HallyApiFactory api)
{
    private async Task<(HttpClient Client, Guid FamilyId)> Family()
    {
        var client = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Ayşe");
        var family = (await (await client.PostIdempotentAsync("/api/v1/families", new { name = "Aile", timeZoneId = "Europe/Istanbul" })).Content.ReadFromJsonAsync<FamilyBody>())!;
        return (client, family.Id);
    }

    [Fact]
    public async Task A_weekly_event_appears_every_week_in_the_calendar_and_can_be_ended()
    {
        var (client, familyId) = await Family();
        var start = new DateTimeOffset(2026, 11, 28, 8, 30, 0, TimeSpan.Zero); // Saturday 11:30 Istanbul
        var created = await client.PostIdempotentAsync($"/api/v1/families/{familyId}/events",
            new { title = "Yüzme", startsAt = start, endsAt = start.AddHours(1), allDay = false, repeat = "Weekly" });
        created.StatusCode.Should().Be(HttpStatusCode.Created);

        var december = await client.GetFromJsonAsync<List<RepeatingEventBody>>(
            $"/api/v1/families/{familyId}/events?from=2026-12-01T00:00:00Z&to=2027-01-01T00:00:00Z");
        december!.Select(e => e.StartsAt.UtcDateTime.Day).Should().Equal(5, 12, 19, 26);
        december.Should().OnlyContain(e => e.Repeat == "Weekly" && e.SeriesStartsAt == start && e.Title == "Yüzme");

        var id = december[0].Id;
        var updated = await client.PutAsJsonAsync($"/api/v1/families/{familyId}/events/{id}",
            new { title = "Yüzme", startsAt = start, endsAt = start.AddHours(1), allDay = false, repeat = "Weekly", repeatUntil = "2026-12-12" });
        updated.StatusCode.Should().Be(HttpStatusCode.OK);

        var after = await client.GetFromJsonAsync<List<RepeatingEventBody>>(
            $"/api/v1/families/{familyId}/events?from=2026-12-01T00:00:00Z&to=2027-01-01T00:00:00Z");
        after!.Select(e => e.StartsAt.UtcDateTime.Day).Should().Equal(5, 12);
        after[0].RepeatUntil.Should().Be("2026-12-12");
    }

    [Fact]
    public async Task Events_without_repeat_stay_one_offs()
    {
        var (client, familyId) = await Family();
        var start = new DateTimeOffset(2026, 12, 3, 9, 0, 0, TimeSpan.Zero);
        await client.PostIdempotentAsync($"/api/v1/families/{familyId}/events", new { title = "Dişçi", startsAt = start, allDay = false });

        var list = await client.GetFromJsonAsync<List<RepeatingEventBody>>(
            $"/api/v1/families/{familyId}/events?from=2026-12-01T00:00:00Z&to=2027-01-01T00:00:00Z");
        list!.Should().ContainSingle().Which.Repeat.Should().Be("None");
    }
}
