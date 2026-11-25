using System.Net;
using System.Net.Http.Json;
using FluentAssertions;
using Hally.Api.Features.Activities;
using Hally.Domain.Activities;

namespace Hally.Api.Tests;

public record ActivityIdeaBody(Guid Id, string Emoji, string Title, string? Hint, string Place, int? Minutes, int Cherries, bool Own, string State);
public record WeatherBody(int TemperatureC, string Sky, bool IsDay);
public record ChildActivitiesBody(WeatherBody? Weather, string? WeatherPlace, int? Age, int DoneToday, int DailyLimit, List<ActivityIdeaBody> Ideas);
public record WeatherPlaceBody(string Name, string? Region, string? Country, double Latitude, double Longitude);
public record OwnActivityBody(Guid Id, string Emoji, string Title, string Place, int Cherries);
public record FamilyActivitiesBody(WeatherPlaceBody? Place, List<OwnActivityBody> Own, int BuiltIn);

[Collection(ApiCollection.Name)]
public class ActivityTests(HallyApiFactory api)
{
    private async Task<(HttpClient Parent, Guid FamilyId, HttpClient Kid)> PairedAsync(int? birthYear)
    {
        var parent = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Ayşe");
        var family = (await (await parent.PostIdempotentAsync("/api/v1/families", new { name = "Yılmaz", timeZoneId = TestZones.Daytime(api.Clock) }))
            .Content.ReadFromJsonAsync<FamilyBody>())!;
        var child = (await (await parent.PostIdempotentAsync($"/api/v1/families/{family.Id}/children", new { firstName = "Ela", birthYear }))
            .Content.ReadFromJsonAsync<ChildBody>())!;
        var code = (await (await parent.PostAsync($"/api/v1/families/{family.Id}/children/{child.Id}/pairing-code", null))
            .Content.ReadFromJsonAsync<PairingCodeBody>())!;
        var paired = (await (await api.CreateClient().PostAsJsonAsync("/api/v1/child/pair", new { code = code.Code })).Content.ReadFromJsonAsync<PairResultBody>())!;
        var kid = api.CreateClient();
        kid.DefaultRequestHeaders.Add("X-Hally-Child", paired.Token);
        return (parent, family.Id, kid);
    }

    [Fact]
    public async Task Ideas_follow_age_and_weather_and_done_goes_through_parent_approval()
    {
        var (parent, familyId, kid) = await PairedAsync(api.Clock.GetUtcNow().Year - 8);
        var f = $"/api/v1/families/{familyId}";

        // No city yet: no weather, indoor and outdoor mixed, only ideas that suit an 8-year-old.
        api.Weather.Now = new WeatherNow(3, "Rain", true);
        var list = (await kid.GetFromJsonAsync<ChildActivitiesBody>("/api/v1/child/activities"))!;
        list.Weather.Should().BeNull();
        list.Age.Should().Be(8);
        list.Ideas.Should().Contain(i => i.Place == "Outdoor").And.Contain(i => i.Place == "Indoor");
        list.Ideas.Should().NotContain(i => i.Title == "Resimli kitaba bak", "it is for ages 2-6");
        (await kid.GetFromJsonAsync<ChildActivitiesBody>("/api/v1/child/activities"))!.Ideas.Select(i => i.Id)
            .Should().Equal(list.Ideas.Select(i => i.Id), "the order stays the same all day");

        // The parent picks a city; it rains, so only indoor ideas.
        (await parent.GetFromJsonAsync<List<WeatherPlaceBody>>("/api/v1/weather/places?q=Ank"))!.Single().Name.Should().Be("Ankara");
        var settings = (await (await parent.PutAsJsonAsync($"{f}/weather-place", new { name = "Ankara", latitude = 39.9334, longitude = 32.8597 }))
            .Content.ReadFromJsonAsync<FamilyActivitiesBody>())!;
        settings.Place!.Latitude.Should().Be(39.9, "only a rounded city point is kept");
        list = (await kid.GetFromJsonAsync<ChildActivitiesBody>("/api/v1/child/activities"))!;
        list.Weather!.Sky.Should().Be("Rain");
        list.WeatherPlace.Should().Be("Ankara");
        list.Ideas.Should().OnlyContain(i => i.Place == "Indoor");

        // Sunny: outdoor ideas come first.
        api.Weather.Now = new WeatherNow(18, "Clear", true);
        list = (await kid.GetFromJsonAsync<ChildActivitiesBody>("/api/v1/child/activities?lang=en"))!;
        list.Ideas[0].Place.Should().Be("Outdoor");
        list.Ideas.Should().Contain(i => i.Title == "Ride your bike");

        // The family's own idea is listed first among its place.
        var own = (await (await parent.PostAsJsonAsync($"{f}/activities", new { title = "Dedeye telefon et", emoji = "☎️", cherries = 4, place = "Indoor" }))
            .Content.ReadFromJsonAsync<OwnActivityBody>())!;
        (await parent.PostAsJsonAsync($"{f}/activities", new { title = "", emoji = "☎️", cherries = 4, place = "Indoor" })).StatusCode
            .Should().Be(HttpStatusCode.UnprocessableEntity);
        list = (await kid.GetFromJsonAsync<ChildActivitiesBody>("/api/v1/child/activities"))!;
        list.Ideas.Should().ContainSingle(i => i.Own).Which.Title.Should().Be("Dedeye telefon et");

        // "Yaptım": waits for a parent, then the cherries land and count for the streak.
        var bike = ActivityCatalog.IdOf("bike");
        list = (await (await kid.PostAsync($"/api/v1/child/activities/{bike}/done", null)).Content.ReadFromJsonAsync<ChildActivitiesBody>())!;
        list.Ideas.Single(i => i.Id == bike).State.Should().Be("Pending");
        list.DoneToday.Should().Be(1);
        var claim = (await parent.GetFromJsonAsync<List<ClaimBody>>($"{f}/claims"))!.Single();
        (claim.Kind, claim.Title, claim.Cherries).Should().Be(("Activity", "Bisiklete bin", 3));
        await parent.PostAsync($"{f}/claims/{claim.Id}/approve", null);
        var home = (await kid.GetFromJsonAsync<ChildHomeBody>("/api/v1/child/home"))!;
        home.Balance.Should().Be(3);
        home.StreakDays.Should().Be(1);
        (await kid.GetFromJsonAsync<ChildActivitiesBody>("/api/v1/child/activities"))!.Ideas.Single(i => i.Id == bike).State.Should().Be("Done");

        // Again the same day changes nothing; three ideas a day at most.
        (await kid.PostAsync($"/api/v1/child/activities/{bike}/done", null)).StatusCode.Should().Be(HttpStatusCode.OK);
        (await kid.PostAsync($"/api/v1/child/activities/{own.Id}/done", null)).StatusCode.Should().Be(HttpStatusCode.OK);
        (await kid.PostAsync($"/api/v1/child/activities/{ActivityCatalog.IdOf("ball")}/done", null)).StatusCode.Should().Be(HttpStatusCode.OK);
        (await kid.PostAsync($"/api/v1/child/activities/{ActivityCatalog.IdOf("walk")}/done", null)).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
        (await kid.PostAsync($"/api/v1/child/activities/{Guid.NewGuid()}/done", null)).StatusCode.Should().Be(HttpStatusCode.NotFound);

        (await parent.DeleteAsync($"{f}/activities/{own.Id}")).StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await parent.GetFromJsonAsync<FamilyActivitiesBody>($"{f}/activities"))!.Own.Should().BeEmpty();
        (await (await parent.PutAsJsonAsync($"{f}/weather-place", new { name = (string?)null })).Content.ReadFromJsonAsync<FamilyActivitiesBody>())!
            .Place.Should().BeNull();
        api.Weather.Now = null;
    }

    [Fact]
    public async Task Another_family_cannot_touch_the_ideas_and_a_child_cannot_claim_them()
    {
        var (parent, familyId, _) = await PairedAsync(null);
        var own = (await (await parent.PostAsJsonAsync($"/api/v1/families/{familyId}/activities", new { title = "Kek yap", emoji = "🧁", cherries = 3, place = "Indoor" }))
            .Content.ReadFromJsonAsync<OwnActivityBody>())!;
        var (stranger, strangerFamily, strangerKid) = await PairedAsync(null);
        (await stranger.GetAsync($"/api/v1/families/{familyId}/activities")).StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await stranger.DeleteAsync($"/api/v1/families/{strangerFamily}/activities/{own.Id}")).StatusCode.Should().Be(HttpStatusCode.NotFound);
        (await strangerKid.PostAsync($"/api/v1/child/activities/{own.Id}/done", null)).StatusCode.Should().Be(HttpStatusCode.NotFound);
        (await strangerKid.GetFromJsonAsync<ChildActivitiesBody>("/api/v1/child/activities"))!.Ideas.Should().NotContain(i => i.Own);
        (await strangerKid.GetFromJsonAsync<ChildActivitiesBody>("/api/v1/child/activities"))!.Ideas.Should().HaveCount(ActivityCatalog.All.Count, "no age: every idea");
    }
}
