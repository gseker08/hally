using System.Net;
using System.Net.Http.Json;
using FluentAssertions;
using Hally.Api.Features.Medications;
using Microsoft.Extensions.DependencyInjection;

namespace Hally.Api.Tests;

public record DoseBody(Guid Id, Guid MedicationId, DateTimeOffset GivenAt, Guid? GivenByUserId, string? GivenByName, string? Note, bool OverrodeWarning);
public record MedicationBody(Guid Id, Guid ChildId, string Name, string? Dose, int MinIntervalMinutes, int? MaxDosesPerDay, bool RemindNextDose,
    string? Notes, bool Active, DoseBody? LastDose, int DosesLast24h, DateTimeOffset? NextAllowedAt);
public record DoseWarningBody(string Code, string Kind, DoseBody LastDose, DateTimeOffset? NextAllowedAt, MedicationBody Medication);

[Collection(ApiCollection.Name)]
public class MedicationTests(HallyApiFactory api)
{
    private async Task<(HttpClient Owner, HttpClient Partner, Guid FamilyId, Guid ChildId)> FamilyWithChild()
    {
        var owner = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Ayşe");
        var family = (await (await owner.PostIdempotentAsync("/api/v1/families", new { name = "Yılmaz" })).Content.ReadFromJsonAsync<FamilyBody>())!;
        var invite = (await (await owner.PostIdempotentAsync($"/api/v1/families/{family.Id}/invitations", null)).Content.ReadFromJsonAsync<InvitationBody>())!;
        var partner = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Mehmet Kaya", "en");
        await partner.PostIdempotentAsync($"/api/v1/invitations/{invite.Token}/accept", null);
        var child = (await (await owner.PostIdempotentAsync($"/api/v1/families/{family.Id}/children", new { firstName = "Ela" })).Content.ReadFromJsonAsync<ChildBody>())!;
        return (owner, partner, family.Id, child.Id);
    }

    private static async Task<MedicationBody> Create(HttpClient client, Guid familyId, Guid childId, int interval = 360, int? max = null)
    {
        var res = await client.PostIdempotentAsync($"/api/v1/families/{familyId}/medications",
            new { childId, name = "Ateş şurubu", dose = "5 ml", minIntervalMinutes = interval, maxDosesPerDay = max });
        res.StatusCode.Should().Be(HttpStatusCode.Created);
        return (await res.Content.ReadFromJsonAsync<MedicationBody>())!;
    }

    private async Task WithClockAdvanced(TimeSpan by, Func<Task> action)
    {
        api.Clock.Advance(by);
        try
        {
            await action();
        }
        finally
        {
            api.Clock.Advance(-by);
        }
    }

    [Fact]
    public async Task A_second_dose_too_soon_is_refused_with_who_gave_the_first_until_confirmed()
    {
        var (owner, partner, familyId, childId) = await FamilyWithChild();
        await owner.PutAsJsonAsync("/api/v1/me/devices", new { platform = "android", token = $"tok-{Guid.NewGuid():N}" });
        var med = await Create(owner, familyId, childId);
        var url = $"/api/v1/families/{familyId}/medications/{med.Id}/doses";

        var first = await partner.PostAsJsonAsync(url, new { });
        first.StatusCode.Should().Be(HttpStatusCode.Created);
        var afterFirst = (await first.Content.ReadFromJsonAsync<MedicationBody>())!;
        afterFirst.LastDose!.GivenByName.Should().Be("Mehmet Kaya");
        afterFirst.NextAllowedAt.Should().BeCloseTo(afterFirst.LastDose.GivenAt.AddHours(6), TimeSpan.FromSeconds(1));

        // The other parent was told.
        api.Push.Sent.Should().Contain(p => p.Message.Title == "Ela: Ateş şurubu verildi" && p.Message.Body.StartsWith("Mehmet "));

        var second = await owner.PostAsJsonAsync(url, new { });
        second.StatusCode.Should().Be(HttpStatusCode.Conflict);
        var warning = (await second.Content.ReadFromJsonAsync<DoseWarningBody>())!;
        warning.Code.Should().Be("medication.too_soon");
        warning.LastDose.GivenByName.Should().Be("Mehmet Kaya");

        var list = (await owner.GetFromJsonAsync<List<MedicationBody>>($"/api/v1/families/{familyId}/medications"))!;
        list.Single().DosesLast24h.Should().Be(1, "nothing was saved");

        var forced = await owner.PostAsJsonAsync(url, new { force = true, note = "Doktor söyledi" });
        forced.StatusCode.Should().Be(HttpStatusCode.Created);
        var doses = (await owner.GetFromJsonAsync<List<DoseBody>>(url))!;
        doses.Should().HaveCount(2);
        doses[0].OverrodeWarning.Should().BeTrue();
        doses[1].OverrodeWarning.Should().BeFalse();

        // Undo a mistaken dose.
        (await owner.DeleteAsync($"{url}/{doses[0].Id}")).StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await owner.GetFromJsonAsync<List<DoseBody>>(url))!.Should().HaveCount(1);
    }

    [Fact]
    public async Task Parallel_presses_save_only_one_dose()
    {
        var (owner, partner, familyId, childId) = await FamilyWithChild();
        var med = await Create(owner, familyId, childId);
        var url = $"/api/v1/families/{familyId}/medications/{med.Id}/doses";

        var results = await Task.WhenAll(owner.PostAsJsonAsync(url, new { }), partner.PostAsJsonAsync(url, new { }));
        results.Select(r => r.StatusCode).Should().BeEquivalentTo([HttpStatusCode.Created, HttpStatusCode.Conflict]);
    }

    [Fact]
    public async Task Daily_limit_and_back_dated_doses_are_checked()
    {
        var (owner, _, familyId, childId) = await FamilyWithChild();
        var med = await Create(owner, familyId, childId, interval: 60, max: 2);
        var url = $"/api/v1/families/{familyId}/medications/{med.Id}/doses";
        var now = api.Clock.GetUtcNow();

        (await owner.PostAsJsonAsync(url, new { givenAt = now.AddHours(-5) })).StatusCode.Should().Be(HttpStatusCode.Created);
        // 30 minutes after a back-dated dose is still too close.
        (await owner.PostAsJsonAsync(url, new { givenAt = now.AddHours(-4).AddMinutes(-30) })).StatusCode.Should().Be(HttpStatusCode.Conflict);
        (await owner.PostAsJsonAsync(url, new { givenAt = now.AddHours(-2) })).StatusCode.Should().Be(HttpStatusCode.Created);

        var third = await owner.PostAsJsonAsync(url, new { });
        third.StatusCode.Should().Be(HttpStatusCode.Conflict);
        var warning = (await third.Content.ReadFromJsonAsync<DoseWarningBody>())!;
        warning.Code.Should().Be("medication.daily_limit");
        warning.NextAllowedAt.Should().BeCloseTo(now.AddHours(19), TimeSpan.FromSeconds(2), "the dose 5 hours ago leaves the 24-hour window");

        (await owner.PostAsJsonAsync(url, new { givenAt = now.AddHours(1) })).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
    }

    [Fact]
    public async Task Next_dose_reminder_reaches_both_adults_once_and_not_for_stale_courses()
    {
        var (owner, partner, familyId, childId) = await FamilyWithChild();
        var med = await Create(owner, familyId, childId, interval: 240);
        (await owner.PostAsJsonAsync($"/api/v1/families/{familyId}/medications/{med.Id}/doses", new { })).StatusCode.Should().Be(HttpStatusCode.Created);

        async Task<int> Run()
        {
            using var scope = api.Services.CreateScope();
            return await scope.ServiceProvider.GetRequiredService<MedicationDueJob>().RunAsync(default);
        }

        await WithClockAdvanced(TimeSpan.FromHours(3), async () => (await Run()).Should().Be(0));
        await WithClockAdvanced(TimeSpan.FromHours(4).Add(TimeSpan.FromMinutes(1)), async () =>
        {
            (await Run()).Should().Be(2);
            (await Run()).Should().Be(0, "once per dose");
        });

        var partnerInbox = (await partner.GetFromJsonAsync<InboxBody>("/api/v1/me/notifications"))!;
        partnerInbox.Items.Should().ContainSingle(n => n.Kind == "MedicationDue").Which.Title.Should().Be("Ela: time for Ateş şurubu");

        // A course nobody continued: no reminders days later.
        var other = await Create(owner, familyId, childId, interval: 60);
        await owner.PostAsJsonAsync($"/api/v1/families/{familyId}/medications/{other.Id}/doses", new { });
        await WithClockAdvanced(TimeSpan.FromHours(5), async () => (await Run()).Should().Be(0));
    }

    [Fact]
    public async Task Ending_a_course_hides_it_but_keeps_history_and_strangers_are_kept_out()
    {
        var (owner, _, familyId, childId) = await FamilyWithChild();
        var med = await Create(owner, familyId, childId);
        (await owner.PutAsJsonAsync($"/api/v1/families/{familyId}/medications/{med.Id}",
            new { childId, name = "Ateş şurubu", dose = "5 ml", minIntervalMinutes = 360, active = false })).StatusCode.Should().Be(HttpStatusCode.OK);
        (await owner.GetFromJsonAsync<List<MedicationBody>>($"/api/v1/families/{familyId}/medications"))!.Should().BeEmpty();
        (await owner.GetFromJsonAsync<List<MedicationBody>>($"/api/v1/families/{familyId}/medications?includeInactive=true"))!.Should().ContainSingle();

        (await owner.PostIdempotentAsync($"/api/v1/families/{familyId}/medications", new { childId, name = "X", minIntervalMinutes = 5 }))
            .StatusCode.Should().Be(HttpStatusCode.BadRequest);

        var stranger = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Yabancı");
        (await stranger.GetAsync($"/api/v1/families/{familyId}/medications")).StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }
}
