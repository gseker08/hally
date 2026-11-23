using System.Net;
using System.Net.Http.Json;
using FluentAssertions;

namespace Hally.Api.Tests;

public record InsightDayBody(DateOnly Date, int ScreenMinutes, int HomeworkMinutes, int ReadingMinutes, int NightSleepMinutes, int NapMinutes, int Feeds,
    int BottleMl, int BreastMinutes, int Solids, int StarsEarned, int StarsSpent, int HabitsDone, int HabitsScheduled, int Doses);
public record HabitInsightBody(Guid Id, string Title, int Streak, int Best, int Done, int Scheduled);
public record HealthSnapshotBody(decimal? HeightCm, decimal? WeightKg, DateOnly? MeasuredOn, int VaccinesOverdue, int VaccinesDueSoon, string? NextAppointment,
    DateTimeOffset? NextAppointmentAt, bool HasAllergies);
public record ChildInsightsBody(Guid ChildId, DateOnly From, DateOnly To, DateOnly Today, int? ScreenGoalMinutes, int? StudyGoalMinutes, List<InsightDayBody> Days,
    List<HabitInsightBody> Habits, List<MedicationInsightBody> Medications, int StarBalance, decimal ExpensesTotal, HealthSnapshotBody Health);
public record MedicationInsightBody(Guid Id, string Name, int Doses);

[Collection(ApiCollection.Name)]
public class InsightsTests(HallyApiFactory api)
{
    [Fact]
    public async Task One_page_brings_a_childs_logs_together()
    {
        var owner = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Ayşe");
        var family = (await (await owner.PostIdempotentAsync("/api/v1/families", new { name = "Yılmaz", timeZoneId = TestZones.Daytime(api.Clock) })).Content.ReadFromJsonAsync<FamilyBody>())!;
        var ela = (await (await owner.PostIdempotentAsync($"/api/v1/families/{family.Id}/children", new { firstName = "Ela" })).Content.ReadFromJsonAsync<ChildBody>())!;
        var f = $"/api/v1/families/{family.Id}";
        var c = $"{f}/children/{ela.Id}";

        await owner.PutAsJsonAsync($"{c}/screen-time/goal", new { dailyMinutes = 60 });
        await owner.PostAsJsonAsync($"{c}/screen-time/entries", new { minutes = 45 });
        await owner.PostAsJsonAsync($"{c}/study/entries", new { kind = "Homework", minutes = 20 });
        await owner.PostAsJsonAsync($"{c}/study/entries", new { kind = "Reading", minutes = 10 });
        var now = api.Clock.GetUtcNow();
        await owner.PostAsJsonAsync($"{c}/feeding", new { kind = "Bottle", amountMl = 120, at = now.AddMinutes(-1) });
        var chore = (await (await owner.PostAsJsonAsync($"{f}/chores", new { title = "Odanı topla", points = 5 })).Content.ReadFromJsonAsync<ChoreBody>())!;
        await owner.PostAsync($"{c}/chores/{chore.Id}/done", null);
        var habit = await owner.PostAsJsonAsync($"{f}/habits", new { childId = ela.Id, title = "Diş fırçalama" });
        habit.EnsureSuccessStatusCode();
        await owner.PutAsJsonAsync($"{c}/health/profile", new { allergies = "Fıstık" });
        await owner.PostAsJsonAsync($"{c}/health/growth", new { heightCm = 102m, weightKg = 16m });

        var res = await owner.GetAsync($"{c}/insights");
        res.StatusCode.Should().Be(HttpStatusCode.OK);
        var insights = (await res.Content.ReadFromJsonAsync<ChildInsightsBody>())!;
        insights.Days.Should().HaveCount(7);
        insights.To.Should().Be(insights.Today);
        insights.ScreenGoalMinutes.Should().Be(60);
        var today = insights.Days[^1];
        today.ScreenMinutes.Should().Be(45);
        today.HomeworkMinutes.Should().Be(20);
        today.ReadingMinutes.Should().Be(10);
        today.Feeds.Should().Be(1);
        today.BottleMl.Should().Be(120);
        today.StarsEarned.Should().Be(5);
        today.HabitsScheduled.Should().Be(1);
        today.HabitsDone.Should().Be(0);
        insights.Days.Take(6).Should().OnlyContain(d => d.ScreenMinutes == 0 && d.HabitsScheduled == 0);
        insights.StarBalance.Should().Be(5);
        insights.Habits.Should().ContainSingle().Which.Title.Should().Be("Diş fırçalama");
        insights.Health.HeightCm.Should().Be(102m);
        insights.Health.HasAllergies.Should().BeTrue();

        var single = (await owner.GetFromJsonAsync<ChildInsightsBody>($"{c}/insights?from={insights.Today:yyyy-MM-dd}&to={insights.Today:yyyy-MM-dd}"))!;
        single.Days.Should().ContainSingle().Which.ScreenMinutes.Should().Be(45);
        (await owner.GetAsync($"{c}/insights?from=2026-01-01&to=2026-03-01")).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);

        var stranger = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "X");
        (await stranger.GetAsync($"{c}/insights")).StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }
}
