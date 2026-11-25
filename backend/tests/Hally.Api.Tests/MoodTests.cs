using System.Net;
using System.Net.Http.Json;
using FluentAssertions;
using Hally.Api.Features.Notifications;
using Hally.Domain.Mood;
using Hally.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;

namespace Hally.Api.Tests;

public record MoodAnswerBody(string Mood, int Cherries);
public record MoodDayBody(DateOnly Date, string? Mood, List<string> Reasons);
public record MoodNudgeBody(DateOnly Date, string Mood, string? Reason);
public record MoodWeekBody(DateOnly From, DateOnly To, DateOnly Today, List<MoodDayBody> Days, string? MostCommon, int MostCommonDays, string? TopReason,
    MoodNudgeBody? Nudge);

[Collection(ApiCollection.Name)]
public class MoodTests(HallyApiFactory api)
{
    private async Task<(HttpClient Parent, Guid FamilyId, Guid ChildId, HttpClient Kid)> PairedAsync()
    {
        var parent = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Ayşe");
        var family = (await (await parent.PostIdempotentAsync("/api/v1/families", new { name = "Yılmaz", timeZoneId = TestZones.Daytime(api.Clock) }))
            .Content.ReadFromJsonAsync<FamilyBody>())!;
        var child = (await (await parent.PostIdempotentAsync($"/api/v1/families/{family.Id}/children", new { firstName = "Ela" }))
            .Content.ReadFromJsonAsync<ChildBody>())!;
        var code = (await (await parent.PostAsync($"/api/v1/families/{family.Id}/children/{child.Id}/pairing-code", null))
            .Content.ReadFromJsonAsync<PairingCodeBody>())!;
        var paired = (await (await api.CreateClient().PostAsJsonAsync("/api/v1/child/pair", new { code = code.Code })).Content.ReadFromJsonAsync<PairResultBody>())!;
        var kid = api.CreateClient();
        kid.DefaultRequestHeaders.Add("X-Hally-Child", paired.Token);
        return (parent, family.Id, child.Id, kid);
    }

    [Fact]
    public async Task Child_answers_once_a_day_for_one_cherry_and_parents_see_the_week()
    {
        var (parent, familyId, childId, kid) = await PairedAsync();

        (await kid.GetFromJsonAsync<ChildHomeBody>("/api/v1/child/home"))!.TodayMood.Should().BeNull();
        (await kid.PostAsJsonAsync("/api/v1/child/mood", new { mood = "Happyish" })).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);

        var first = (await (await kid.PostAsJsonAsync("/api/v1/child/mood", new { mood = "Sad", reasons = new[] { "School" } })).Content.ReadFromJsonAsync<MoodAnswerBody>())!;
        first.Cherries.Should().Be(1);
        var again = (await (await kid.PostAsJsonAsync("/api/v1/child/mood", new { mood = "Good", reasons = new[] { "Friends", "School" } }))
            .Content.ReadFromJsonAsync<MoodAnswerBody>())!;
        again.Cherries.Should().Be(0, "changing the answer does not earn another cherry");

        var home = (await kid.GetFromJsonAsync<ChildHomeBody>("/api/v1/child/home"))!;
        home.TodayMood.Should().Be("Good");
        home.Balance.Should().Be(1);

        var url = $"/api/v1/families/{familyId}/children/{childId}/moods";
        var week = (await parent.GetFromJsonAsync<MoodWeekBody>(url))!;
        week.Days.Should().HaveCount(7);
        week.Days[^1].Mood.Should().Be("Good");
        week.Days[^1].Reasons.Should().Equal("Friends", "School");
        week.MostCommon.Should().Be("Good");
        week.TopReason.Should().Be("Friends");
        week.Nudge.Should().BeNull();

        // Yesterday was hard: a gentle nudge.
        using (var scope = api.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<HallyDbContext>();
            var check = new MoodCheck(familyId, childId, week.Today.AddDays(-1), api.Clock.GetUtcNow());
            check.Answer(Mood.Angry, [MoodReason.Home]);
            db.MoodChecks.Add(check);
            var old = new MoodCheck(familyId, childId, week.Today.AddDays(-120), api.Clock.GetUtcNow());
            old.Answer(Mood.Okay, []);
            db.MoodChecks.Add(old);
            await db.SaveChangesAsync();
        }

        week = (await parent.GetFromJsonAsync<MoodWeekBody>(url))!;
        week.Nudge.Should().Be(new MoodNudgeBody(week.Today.AddDays(-1), "Angry", "Home"));
        (await parent.GetAsync($"{url}?from=2026-01-01&to=2026-03-01")).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);

        using (var scope = api.Services.CreateScope())
        {
            await scope.ServiceProvider.GetRequiredService<RetentionJob>().RunAsync(CancellationToken.None);
            var db = scope.ServiceProvider.GetRequiredService<HallyDbContext>();
            (await db.MoodChecks.CountAsync(m => m.ChildId == childId)).Should().Be(2, "answers older than 90 days are deleted");
        }
    }

    [Fact]
    public async Task Caregivers_cannot_see_a_childs_moods()
    {
        var (parent, familyId, childId, _) = await PairedAsync();
        var invite = (await (await parent.PostIdempotentAsync($"/api/v1/families/{familyId}/invitations", new { role = "caregiver" })).Content.ReadFromJsonAsync<RoleInvitationBody>())!;
        var caregiver = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Zeynep");
        await caregiver.PostIdempotentAsync($"/api/v1/invitations/{invite.Token}/accept", null);
        (await caregiver.GetAsync($"/api/v1/families/{familyId}/children/{childId}/moods")).StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }
}
