using System.Net;
using System.Net.Http.Json;
using FluentAssertions;
using Hally.Domain.Goals;
using Hally.Domain.Notifications;
using Hally.Domain.Points;
using Hally.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;

namespace Hally.Api.Tests;

public record GoalContributorBody(string Kind, Guid Id, string Name, string? Color, int Cherries);
public record FamilyGoalBody(Guid Id, DateOnly WeekStart, DateOnly WeekEnd, int DaysLeft, string RewardTitle, string RewardEmoji, int Target, int Total, bool Repeat,
    DateTimeOffset? ReachedAt, List<GoalContributorBody> Contributors);
public record FamilyGoalStateBody(DateOnly Today, FamilyGoalBody? Goal, int LastWeekTotal, int SuggestedTarget);

[Collection(ApiCollection.Name)]
public class FamilyGoalTests(HallyApiFactory api)
{
    [Fact]
    public async Task Everyone_fills_the_weekly_goal_without_touching_the_jar_and_parents_hear_when_it_is_reached()
    {
        var ayse = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Ayşe Yılmaz");
        var family = (await (await ayse.PostIdempotentAsync("/api/v1/families", new { name = "Yılmaz", timeZoneId = TestZones.Daytime(api.Clock) }))
            .Content.ReadFromJsonAsync<FamilyBody>())!;
        var f = $"/api/v1/families/{family.Id}";
        var ela = (await (await ayse.PostIdempotentAsync($"{f}/children", new { firstName = "Ela" })).Content.ReadFromJsonAsync<ChildBody>())!;
        var can = (await (await ayse.PostIdempotentAsync($"{f}/children", new { firstName = "Can" })).Content.ReadFromJsonAsync<ChildBody>())!;
        var code = (await (await ayse.PostAsync($"{f}/children/{ela.Id}/pairing-code", null)).Content.ReadFromJsonAsync<PairingCodeBody>())!;
        var paired = (await (await api.CreateClient().PostAsJsonAsync("/api/v1/child/pair", new { code = code.Code })).Content.ReadFromJsonAsync<PairResultBody>())!;
        var kid = api.CreateClient();
        kid.DefaultRequestHeaders.Add("X-Hally-Child", paired.Token);

        var state = (await ayse.GetFromJsonAsync<FamilyGoalStateBody>($"{f}/goal"))!;
        state.Goal.Should().BeNull();
        state.SuggestedTarget.Should().Be(80, "no history yet");

        // Last week Ela earned 50 → a target a bit above.
        var week = FamilyGoal.WeekOf(state.Today);
        await Seed(db =>
        {
            db.PointEntries.Add(PointEntry.ForStreakBonus(family.Id, ela.Id, 7, week.AddDays(-3), api.Clock.GetUtcNow()));
            for (var i = 0; i < 5; i++)
            {
                db.PointEntries.Add(PointEntry.ForChoreClaim(family.Id, ela.Id, null, "Eski", 9, null, week.AddDays(-2), api.Clock.GetUtcNow()));
            }
        });
        state = (await ayse.GetFromJsonAsync<FamilyGoalStateBody>($"{f}/goal"))!;
        state.LastWeekTotal.Should().Be(50);
        state.SuggestedTarget.Should().Be(60);

        (await ayse.PutAsJsonAsync($"{f}/goal", new { rewardTitle = "Cumartesi piknik", rewardEmoji = "🧺", target = 5, repeat = true })).StatusCode
            .Should().Be(HttpStatusCode.UnprocessableEntity);
        state = (await (await ayse.PutAsJsonAsync($"{f}/goal", new { rewardTitle = "Cumartesi piknik", rewardEmoji = "🧺", target = 30, repeat = true }))
            .Content.ReadFromJsonAsync<FamilyGoalStateBody>())!;
        state.Goal!.Total.Should().Be(0);
        state.Goal.Contributors.Select(c => (c.Kind, c.Name)).Should().Equal(("Child", "Ela"), ("Child", "Can"), ("Adult", "Ayşe"));

        // Children's cherries count, spending does not; a parent's finished task counts 2.
        await Seed(db =>
        {
            db.PointEntries.Add(PointEntry.ForChoreClaim(family.Id, ela.Id, null, "Odanı topla", 12, null, state.Today, api.Clock.GetUtcNow()));
            db.PointEntries.Add(PointEntry.ForChoreClaim(family.Id, can.Id, null, "Sofrayı kur", 10, null, state.Today, api.Clock.GetUtcNow()));
        });
        var task = (await (await ayse.PostIdempotentAsync($"{f}/tasks", new { title = "Fatura öde" })).Content.ReadFromJsonAsync<TaskBody>())!;
        await ayse.PostIdempotentAsync($"{f}/tasks/{task.Id}/complete", null);
        state = (await kid.GetFromJsonAsync<FamilyGoalStateBody>("/api/v1/child/goal"))!;
        state.Goal!.Contributors.Select(c => c.Cherries).Should().Equal(12, 10, 2);
        state.Goal.Total.Should().Be(24);
        state.Goal.ReachedAt.Should().BeNull();

        // Reaching it: one note per parent, once; the jar keeps its cherries.
        await Seed(db => db.PointEntries.Add(PointEntry.ForHabit(family.Id, can.Id, null, "Diş", null, state.Today, api.Clock.GetUtcNow())));
        await Seed(db => db.PointEntries.Add(PointEntry.ForChoreClaim(family.Id, can.Id, null, "Çiçek", 5, null, state.Today, api.Clock.GetUtcNow())));
        using (var scope = api.Services.CreateScope())
        {
            await scope.ServiceProvider.GetRequiredService<Hally.Api.Features.Goals.FamilyGoalService>().CheckAllAsync(default);
        }

        state = (await ayse.GetFromJsonAsync<FamilyGoalStateBody>($"{f}/goal"))!;
        state.Goal!.Total.Should().Be(30);
        state.Goal.ReachedAt.Should().NotBeNull();
        (await kid.GetFromJsonAsync<ChildHomeBody>("/api/v1/child/home"))!.Balance.Should().Be(12 + 50);
        await Seed(async db => (await db.Notifications.CountAsync(n => n.FamilyId == family.Id && n.Kind == NotificationKind.FamilyGoalReached)).Should().Be(1));

        // A higher target opens it again; ending it removes this week's goal.
        state = (await (await ayse.PutAsJsonAsync($"{f}/goal", new { rewardTitle = "Sinema", rewardEmoji = "🎬", target = 40, repeat = false }))
            .Content.ReadFromJsonAsync<FamilyGoalStateBody>())!;
        state.Goal!.ReachedAt.Should().BeNull();
        state.Goal.RewardTitle.Should().Be("Sinema");
        state = (await (await ayse.DeleteAsync($"{f}/goal")).Content.ReadFromJsonAsync<FamilyGoalStateBody>())!;
        state.Goal.Should().BeNull();
    }

    [Fact]
    public async Task A_repeating_goal_starts_again_on_monday_and_strangers_cannot_see_it()
    {
        var ayse = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Ayşe");
        var family = (await (await ayse.PostIdempotentAsync("/api/v1/families", new { name = "Yılmaz", timeZoneId = TestZones.Daytime(api.Clock) }))
            .Content.ReadFromJsonAsync<FamilyBody>())!;
        var f = $"/api/v1/families/{family.Id}";
        var today = (await ayse.GetFromJsonAsync<FamilyGoalStateBody>($"{f}/goal"))!.Today;
        await Seed(db => db.FamilyGoals.Add(new FamilyGoal(family.Id, FamilyGoal.WeekOf(today).AddDays(-7), "Pizza akşamı", "🍕", 100, true, null, api.Clock.GetUtcNow())));

        var state = (await ayse.GetFromJsonAsync<FamilyGoalStateBody>($"{f}/goal"))!;
        state.Goal!.RewardTitle.Should().Be("Pizza akşamı");
        state.Goal.WeekStart.Should().Be(FamilyGoal.WeekOf(today));
        state.Goal.DaysLeft.Should().Be(state.Goal.WeekEnd.DayNumber - today.DayNumber);

        var stranger = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Mehmet");
        (await stranger.GetAsync($"{f}/goal")).StatusCode.Should().Be(HttpStatusCode.Forbidden);

        // Ending it stops the repeat too.
        await ayse.DeleteAsync($"{f}/goal");
        (await ayse.GetFromJsonAsync<FamilyGoalStateBody>($"{f}/goal"))!.Goal.Should().BeNull();
    }

    private async Task Seed(Action<HallyDbContext> act) => await Seed(db =>
    {
        act(db);
        return Task.CompletedTask;
    });

    private async Task Seed(Func<HallyDbContext, Task> act)
    {
        using var scope = api.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<HallyDbContext>();
        await act(db);
        await db.SaveChangesAsync();
    }
}
