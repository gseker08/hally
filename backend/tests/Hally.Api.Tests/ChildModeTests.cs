using System.Net;
using System.Net.Http.Json;
using FluentAssertions;
using Hally.Domain.ChildMode;
using Hally.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;

namespace Hally.Api.Tests;

public record PairingCodeBody(string Code, DateTimeOffset ExpiresAt);
public record ChildProfileBody(Guid Id, string FirstName, string Color, bool HasPhoto);
public record PairResultBody(string Token, Guid FamilyId, ChildProfileBody Child);
public record ChildItemBody(Guid Id, string Kind, string Title, int Cherries, string State);
public record ChildRewardBody(Guid Id, string Title, int Cost, int? ScreenMinutes);
public record ChildScreenStatusBody(DateOnly Day, int? GoalMinutes, int BonusMinutes, int? LimitMinutes, int UsedSeconds, bool Locked);
public record ChildHomeBody(ChildProfileBody Child, string FamilyName, int Balance, int WeekCherries, int StreakDays, int NextBonusIn,
    bool RequireApproval, List<ChildItemBody> Today, List<ChildRewardBody> Rewards, ChildScreenStatusBody Screen);
public record ClaimBody(Guid Id, Guid ChildId, string ChildName, string Kind, string Title, int Cherries, DateOnly Day);
public record ChildDeviceBody(Guid Id, string? Name);

[Collection(ApiCollection.Name)]
public class ChildModeTests(HallyApiFactory api)
{
    private async Task<(HttpClient Parent, Guid FamilyId, Guid ChildId, HttpClient Kid, string Token)> PairedAsync()
    {
        var parent = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Ayşe");
        var family = (await (await parent.PostIdempotentAsync("/api/v1/families", new { name = "Yılmaz", timeZoneId = TestZones.Daytime(api.Clock) }))
            .Content.ReadFromJsonAsync<FamilyBody>())!;
        var child = (await (await parent.PostIdempotentAsync($"/api/v1/families/{family.Id}/children", new { firstName = "Ela" }))
            .Content.ReadFromJsonAsync<ChildBody>())!;

        var code = (await (await parent.PostAsync($"/api/v1/families/{family.Id}/children/{child.Id}/pairing-code", null))
            .Content.ReadFromJsonAsync<PairingCodeBody>())!;
        code.Code.Should().MatchRegex("^[0-9]{6}$");

        var anon = api.CreateClient();
        var res = await anon.PostAsJsonAsync("/api/v1/child/pair", new { code = code.Code, deviceName = "Ela'nın telefonu" });
        res.StatusCode.Should().Be(HttpStatusCode.OK);
        var paired = (await res.Content.ReadFromJsonAsync<PairResultBody>())!;
        paired.Child.FirstName.Should().Be("Ela");

        // A code works once.
        (await anon.PostAsJsonAsync("/api/v1/child/pair", new { code = code.Code })).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);

        var kid = api.CreateClient();
        kid.DefaultRequestHeaders.Add("X-Hally-Child", paired.Token);
        return (parent, family.Id, child.Id, kid, paired.Token);
    }

    [Fact]
    public async Task A_child_phone_reaches_only_child_endpoints()
    {
        var (parent, familyId, childId, kid, token) = await PairedAsync();

        (await kid.GetAsync("/api/v1/child/home")).StatusCode.Should().Be(HttpStatusCode.OK);
        (await kid.GetAsync("/api/v1/me")).StatusCode.Should().Be(HttpStatusCode.Unauthorized);
        (await kid.GetAsync($"/api/v1/families/{familyId}")).StatusCode.Should().Be(HttpStatusCode.Unauthorized);
        // A parent's token does not open child endpoints, and nobody gets in without a device.
        (await parent.GetAsync("/api/v1/child/home")).StatusCode.Should().Be(HttpStatusCode.Unauthorized);
        (await api.CreateClient().GetAsync("/api/v1/child/home")).StatusCode.Should().Be(HttpStatusCode.Unauthorized);

        var devices = await parent.GetFromJsonAsync<List<ChildDeviceBody>>($"/api/v1/families/{familyId}/children/{childId}/devices");
        var device = devices.Should().ContainSingle().Subject;
        device.Name.Should().Be("Ela'nın telefonu");
        (await parent.DeleteAsync($"/api/v1/families/{familyId}/children/{childId}/devices/{device.Id}")).StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await kid.GetAsync("/api/v1/child/home")).StatusCode.Should().Be(HttpStatusCode.Unauthorized);
    }

    [Fact]
    public async Task Cherries_land_after_a_parent_approves()
    {
        var (parent, familyId, childId, kid, _) = await PairedAsync();
        var f = $"/api/v1/families/{familyId}";
        var chore = (await (await parent.PostAsJsonAsync($"{f}/chores", new { title = "Odanı topla", points = 5 })).Content.ReadFromJsonAsync<ChoreBody>())!;
        var habit = (await (await parent.PostAsJsonAsync($"{f}/habits", new { childId, title = "Diş fırçalama" })).Content.ReadFromJsonAsync<HabitsBody>())!.Habits.Single();

        var home = (await kid.GetFromJsonAsync<ChildHomeBody>("/api/v1/child/home"))!;
        home.RequireApproval.Should().BeTrue();
        home.Today.Select(i => (i.Title, i.Cherries, i.State)).Should().Equal(("Odanı topla", 5, "Todo"), ("Diş fırçalama", 1, "Todo"));

        home = (await (await kid.PostAsync($"/api/v1/child/chores/{chore.Id}/done", null)).Content.ReadFromJsonAsync<ChildHomeBody>())!;
        await kid.PostAsync($"/api/v1/child/chores/{chore.Id}/done", null); // a double tap changes nothing
        home = (await (await kid.PostAsync($"/api/v1/child/habits/{habit.Id}/done", null)).Content.ReadFromJsonAsync<ChildHomeBody>())!;
        home.Today.Select(i => i.State).Should().Equal("Pending", "Pending");
        home.Balance.Should().Be(0);

        var claims = (await parent.GetFromJsonAsync<List<ClaimBody>>($"{f}/claims"))!;
        claims.Select(c => (c.ChildName, c.Title, c.Cherries)).Should().Equal(("Ela", "Odanı topla", 5), ("Ela", "Diş fırçalama", 1));
        using (var scope = api.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<HallyDbContext>();
            (await db.Notifications.CountAsync(n => n.FamilyId == familyId && n.Kind == Domain.Notifications.NotificationKind.ChildClaim)).Should().Be(2);
        }

        (await parent.PostAsync($"{f}/claims/{claims[0].Id}/approve", null)).StatusCode.Should().Be(HttpStatusCode.OK);
        var left = (await (await parent.PostAsync($"{f}/claims/{claims[1].Id}/reject", null)).Content.ReadFromJsonAsync<List<ClaimBody>>())!;
        left.Should().BeEmpty();
        (await parent.PostAsync($"{f}/claims/{claims[1].Id}/approve", null)).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);

        home = (await kid.GetFromJsonAsync<ChildHomeBody>("/api/v1/child/home"))!;
        home.Balance.Should().Be(5);
        home.StreakDays.Should().Be(1);
        home.Today.Select(i => i.State).Should().Equal("Done", "Todo"); // a rejected one can be tried again

        // The parents' chore board shows the same cherries.
        var board = (await parent.GetFromJsonAsync<PointsBoardBody>($"{f}/points"))!;
        board.Children.Single().Balance.Should().Be(5);

        // Without approval the cherry comes at once, and the habit is ticked for the parents too.
        await parent.PutAsJsonAsync($"{f}/child-mode", new { requireApproval = false });
        home = (await (await kid.PostAsync($"/api/v1/child/habits/{habit.Id}/done", null)).Content.ReadFromJsonAsync<ChildHomeBody>())!;
        home.Balance.Should().Be(6);
        home.Today.Select(i => i.State).Should().Equal("Done", "Done");
        var habits = (await parent.GetFromJsonAsync<HabitsBody>($"{f}/habits"))!;
        habits.Habits.Single().DoneToday.Should().BeTrue();
    }

    [Fact]
    public async Task Screen_time_locks_and_extra_minutes_open_it_again()
    {
        var (parent, familyId, childId, kid, _) = await PairedAsync();
        var f = $"/api/v1/families/{familyId}";
        await parent.PutAsJsonAsync($"{f}/children/{childId}/screen-time/goal", new { dailyMinutes = 30 });

        var screen = (await (await kid.PostAsJsonAsync("/api/v1/child/screen", new { usedSeconds = 20 * 60 })).Content.ReadFromJsonAsync<ChildScreenStatusBody>())!;
        screen.Locked.Should().BeFalse();
        screen.LimitMinutes.Should().Be(30);
        screen = (await (await kid.PostAsJsonAsync("/api/v1/child/screen", new { usedSeconds = 31 * 60 })).Content.ReadFromJsonAsync<ChildScreenStatusBody>())!;
        screen.Locked.Should().BeTrue();
        // A late report never lowers the total.
        screen = (await (await kid.PostAsJsonAsync("/api/v1/child/screen", new { usedSeconds = 60 })).Content.ReadFromJsonAsync<ChildScreenStatusBody>())!;
        screen.UsedSeconds.Should().Be(31 * 60);

        (await kid.PostAsJsonAsync("/api/v1/child/screen/request", new { minutes = 15 })).StatusCode.Should().Be(HttpStatusCode.NoContent);
        await kid.PostAsJsonAsync("/api/v1/child/screen/request", new { minutes = 15 });
        using (var scope = api.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<HallyDbContext>();
            (await db.Notifications.CountAsync(n => n.FamilyId == familyId && n.Kind == Domain.Notifications.NotificationKind.ChildTimeRequest)).Should().Be(1);
            (await db.Notifications.CountAsync(n => n.FamilyId == familyId && n.Kind == Domain.Notifications.NotificationKind.ScreenTimeGoal)).Should().Be(1);
        }

        screen = (await (await parent.PostAsJsonAsync($"{f}/children/{childId}/screen-bonus", new { minutes = 15 })).Content.ReadFromJsonAsync<ChildScreenStatusBody>())!;
        screen.Should().Match<ChildScreenStatusBody>(s => s.BonusMinutes == 15 && s.LimitMinutes == 45 && !s.Locked);

        // Cherries buy screen time too.
        await parent.PutAsJsonAsync($"{f}/child-mode", new { requireApproval = false });
        var chore = (await (await parent.PostAsJsonAsync($"{f}/chores", new { title = "Sofrayı kur", points = 20 })).Content.ReadFromJsonAsync<ChoreBody>())!;
        var reward = (await (await parent.PostAsJsonAsync($"{f}/rewards", new { title = "15 dk ekstra", cost = 20, screenMinutes = 15 }))
            .Content.ReadFromJsonAsync<ChildRewardBody>())!;
        reward.ScreenMinutes.Should().Be(15);
        (await kid.PostAsync($"/api/v1/child/rewards/{reward.Id}/redeem", null)).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
        await kid.PostAsync($"/api/v1/child/chores/{chore.Id}/done", null);
        var home = (await (await kid.PostAsync($"/api/v1/child/rewards/{reward.Id}/redeem", null)).Content.ReadFromJsonAsync<ChildHomeBody>())!;
        home.Balance.Should().Be(0);
        home.Screen.LimitMinutes.Should().Be(60);
    }

    [Fact]
    public void Streak_counts_days_in_a_row_and_forgives_an_empty_today()
    {
        var today = new DateOnly(2026, 11, 25);
        var days = Enumerable.Range(1, 6).Select(i => today.AddDays(-i)).ToHashSet();
        CherryStreak.Length(days, today).Should().Be(6);
        days.Add(today);
        CherryStreak.Length(days, today).Should().Be(7);
        days.Remove(today.AddDays(-3));
        CherryStreak.Length(days, today).Should().Be(3);
        CherryStreak.Length(new HashSet<DateOnly>(), today).Should().Be(0);
    }
}
