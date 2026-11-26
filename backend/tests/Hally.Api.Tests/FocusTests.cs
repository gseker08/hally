using System.Net;
using System.Net.Http.Json;
using FluentAssertions;

namespace Hally.Api.Tests;

public record FocusBody(List<string> Areas, bool SetupDone);

[Collection(ApiCollection.Name)]
public class FocusTests(HallyApiFactory api)
{
    private static string Email() => $"{Guid.NewGuid():N}@example.com";

    [Fact]
    public async Task The_setup_wizard_saves_each_parents_own_areas_in_order()
    {
        var ayse = await api.SignInAsync(Email(), "Ayşe");
        var family = (await (await ayse.PostIdempotentAsync("/api/v1/families", new { name = "Yılmaz" })).Content.ReadFromJsonAsync<FamilyBody>())!;
        var f = $"/api/v1/families/{family.Id}";

        var fresh = (await ayse.GetFromJsonAsync<FocusBody>($"{f}/focus"))!;
        fresh.Areas.Should().BeEmpty();
        fresh.SetupDone.Should().BeFalse("a new member has not seen the wizard yet");

        var saved = (await (await ayse.PutAsJsonAsync($"{f}/focus", new { areas = new[] { "school", "baby", "tasks", "school" } }))
            .Content.ReadFromJsonAsync<FocusBody>())!;
        saved.Areas.Should().Equal("school", "baby", "tasks");
        saved.SetupDone.Should().BeTrue();

        // The partner chooses separately.
        var invite = (await (await ayse.PostIdempotentAsync($"{f}/invitations", null)).Content.ReadFromJsonAsync<RoleInvitationBody>())!;
        var mehmet = await api.SignInAsync(Email(), "Mehmet");
        (await mehmet.PostIdempotentAsync($"/api/v1/invitations/{invite.Token}/accept", null)).EnsureSuccessStatusCode();
        (await mehmet.GetFromJsonAsync<FocusBody>($"{f}/focus"))!.SetupDone.Should().BeFalse();

        // "Atla" saves nothing chosen but still counts as done.
        var skipped = (await (await mehmet.PutAsJsonAsync($"{f}/focus", new { areas = Array.Empty<string>() })).Content.ReadFromJsonAsync<FocusBody>())!;
        skipped.Should().BeEquivalentTo(new FocusBody([], true));
        (await ayse.GetFromJsonAsync<FocusBody>($"{f}/focus"))!.Areas.Should().Equal("school", "baby", "tasks");
    }

    [Fact]
    public async Task Unknown_areas_and_strangers_are_refused()
    {
        var ayse = await api.SignInAsync(Email(), "Ayşe");
        var family = (await (await ayse.PostIdempotentAsync("/api/v1/families", new { name = "Yılmaz" })).Content.ReadFromJsonAsync<FamilyBody>())!;
        var f = $"/api/v1/families/{family.Id}";

        (await ayse.PutAsJsonAsync($"{f}/focus", new { areas = new[] { "school", "gaming" } })).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
        (await ayse.GetFromJsonAsync<FocusBody>($"{f}/focus"))!.SetupDone.Should().BeFalse();

        var stranger = await api.SignInAsync(Email(), "Can");
        (await stranger.GetAsync($"{f}/focus")).StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }
}
