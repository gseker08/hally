using System.Net;
using System.Net.Http.Json;
using FluentAssertions;
using Hally.Domain.Sleep;

namespace Hally.Api.Tests;

public record SleepEntryBody(Guid Id, Guid ChildId, string Kind, DateTimeOffset StartedAt, DateTimeOffset? EndedAt, int Minutes,
    string? StartedByName, string? EndedByName, string? Note);
public record ChildSleepStatusBody(Guid ChildId, SleepEntryBody? Asleep, SleepEntryBody? LastSleep);
public record SleepDayBody(DateOnly Date, int NightMinutes, int NapMinutes, int Naps);
public record ChildSleepHistoryBody(Guid ChildId, List<SleepDayBody> Days, List<SleepEntryBody> Entries, int AverageNightMinutes, int AverageNapMinutes);

[Collection(ApiCollection.Name)]
public class SleepTests(HallyApiFactory api)
{
    private async Task<(HttpClient Owner, HttpClient Partner, Guid FamilyId, Guid ChildId)> FamilyWithChild()
    {
        var owner = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Ayşe");
        var family = (await (await owner.PostIdempotentAsync("/api/v1/families", new { name = "Yılmaz" })).Content.ReadFromJsonAsync<FamilyBody>())!;
        var invite = (await (await owner.PostIdempotentAsync($"/api/v1/families/{family.Id}/invitations", null)).Content.ReadFromJsonAsync<InvitationBody>())!;
        var partner = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Mehmet");
        await partner.PostIdempotentAsync($"/api/v1/invitations/{invite.Token}/accept", null);
        var child = (await (await owner.PostIdempotentAsync($"/api/v1/families/{family.Id}/children", new { firstName = "Can" })).Content.ReadFromJsonAsync<ChildBody>())!;
        return (owner, partner, family.Id, child.Id);
    }

    [Fact]
    public void Sleep_days_run_from_six_to_six_and_kind_is_guessed_from_the_hour()
    {
        var tz = "Europe/Istanbul";
        SleepEntry.SleepDay(new DateTimeOffset(2026, 11, 22, 21, 0, 0, TimeSpan.FromHours(3)), tz).Should().Be(new DateOnly(2026, 11, 22));
        SleepEntry.SleepDay(new DateTimeOffset(2026, 11, 23, 0, 30, 0, TimeSpan.FromHours(3)), tz).Should().Be(new DateOnly(2026, 11, 22));
        SleepEntry.SleepDay(new DateTimeOffset(2026, 11, 23, 13, 0, 0, TimeSpan.FromHours(3)), tz).Should().Be(new DateOnly(2026, 11, 23));
        SleepEntry.GuessKind(new DateTimeOffset(2026, 11, 22, 20, 0, 0, TimeSpan.Zero)).Should().Be(SleepKind.Night);
        SleepEntry.GuessKind(new DateTimeOffset(2026, 11, 22, 13, 0, 0, TimeSpan.Zero)).Should().Be(SleepKind.Nap);
    }

    [Fact]
    public async Task Asleep_and_awake_are_shared_and_a_double_tap_keeps_one_sleep()
    {
        var (owner, partner, familyId, childId) = await FamilyWithChild();
        var url = $"/api/v1/families/{familyId}/children/{childId}/sleep";
        var at = api.Clock.GetUtcNow().AddMinutes(-90);

        var started = (await (await owner.PostAsJsonAsync($"{url}/start", new { at, kind = "Nap" })).Content.ReadFromJsonAsync<ChildSleepStatusBody>())!;
        started.Asleep!.StartedByName.Should().Be("Ayşe");
        (await (await partner.PostAsJsonAsync($"{url}/start", new { })).Content.ReadFromJsonAsync<ChildSleepStatusBody>())!
            .Asleep!.Id.Should().Be(started.Asleep.Id, "already asleep");

        var status = (await partner.GetFromJsonAsync<List<ChildSleepStatusBody>>($"/api/v1/families/{familyId}/sleep"))!;
        status.Single().Asleep!.Minutes.Should().BeInRange(89, 91);

        var woke = (await (await partner.PostAsJsonAsync($"{url}/stop", new { note = "Huysuz uyandı" })).Content.ReadFromJsonAsync<ChildSleepStatusBody>())!;
        woke.Asleep.Should().BeNull();
        woke.LastSleep!.EndedByName.Should().Be("Mehmet");
        woke.LastSleep.Kind.Should().Be("Nap");
        woke.LastSleep.Note.Should().Be("Huysuz uyandı");

        var history = (await owner.GetFromJsonAsync<ChildSleepHistoryBody>(url))!;
        history.Days.Should().HaveCount(7);
        history.Days.Sum(d => d.NapMinutes).Should().BeInRange(89, 91);
        history.Days.Sum(d => d.Naps).Should().Be(1);
    }

    [Fact]
    public async Task Added_sleeps_count_by_sleep_day_and_overlaps_are_refused()
    {
        var (owner, _, familyId, childId) = await FamilyWithChild();
        var url = $"/api/v1/families/{familyId}/children/{childId}/sleep";
        var now = api.Clock.GetUtcNow();
        var night = now.AddDays(-2).AddHours(-10);

        var added = await owner.PostAsJsonAsync($"{url}/entries", new { startedAt = night, endedAt = night.AddHours(10), kind = "Night" });
        added.StatusCode.Should().Be(HttpStatusCode.Created);
        (await added.Content.ReadFromJsonAsync<SleepEntryBody>())!.Minutes.Should().Be(600);

        (await owner.PostAsJsonAsync($"{url}/entries", new { startedAt = night.AddHours(2), endedAt = night.AddHours(3) }))
            .StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
        (await owner.PostAsJsonAsync($"{url}/entries", new { startedAt = night.AddHours(3), endedAt = night.AddHours(2) }))
            .StatusCode.Should().Be(HttpStatusCode.BadRequest);

        var history = (await owner.GetFromJsonAsync<ChildSleepHistoryBody>(url))!;
        history.Days.Sum(d => d.NightMinutes).Should().Be(600);
        history.AverageNightMinutes.Should().Be(600, "only days with a record count");

        var entry = history.Entries.Single();
        (await owner.DeleteAsync($"{url}/entries/{entry.Id}")).StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await owner.GetFromJsonAsync<ChildSleepHistoryBody>(url))!.Entries.Should().BeEmpty();
    }

    [Fact]
    public async Task Strangers_cannot_read_sleep()
    {
        var (_, _, familyId, childId) = await FamilyWithChild();
        var stranger = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Yabancı");
        (await stranger.GetAsync($"/api/v1/families/{familyId}/children/{childId}/sleep")).StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }
}
