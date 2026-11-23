using System.Net;
using System.Net.Http.Json;
using FluentAssertions;
using Hally.Domain.Habits;

namespace Hally.Api.Tests;

public record HabitBody(Guid Id, Guid ChildId, string Title, int Days, bool DoneToday, bool DueToday, int Streak, int Best, List<bool?> LastSeven);
public record HabitsBody(DateOnly Today, List<HabitBody> Habits);

[Collection(ApiCollection.Name)]
public class HabitsTests(HallyApiFactory api)
{
    [Fact]
    public void Streak_skips_unscheduled_days_and_today_does_not_break_it()
    {
        // Weekdays only (Mon-Fri). 2026-11-23 is a Monday.
        var habit = new Habit(Guid.NewGuid(), Guid.NewGuid(), "Diş fırçalama", 0b001_1111, DateTimeOffset.UtcNow);
        var monday = new DateOnly(2026, 11, 23);
        var done = new HashSet<DateOnly> { new(2026, 11, 18), new(2026, 11, 19), new(2026, 11, 20) }; // Wed-Fri
        habit.Streak(done, monday, monday.AddDays(-30)).Should().Be(3, "the weekend is not scheduled and Monday is not over");
        done.Add(monday);
        habit.Streak(done, monday, monday.AddDays(-30)).Should().Be(4);
        habit.Streak(done, monday.AddDays(1), monday.AddDays(-30)).Should().Be(4);
        habit.Streak(done, monday.AddDays(2), monday.AddDays(-30)).Should().Be(0, "Tuesday was missed");
        habit.Best(done, monday.AddDays(2), monday.AddDays(-30)).Should().Be(4);
    }

    [Fact]
    public async Task Parents_check_habits_for_today_and_the_last_week()
    {
        var owner = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Ayşe");
        var family = (await (await owner.PostIdempotentAsync("/api/v1/families", new { name = "Yılmaz" })).Content.ReadFromJsonAsync<FamilyBody>())!;
        var child = (await (await owner.PostIdempotentAsync($"/api/v1/families/{family.Id}/children", new { firstName = "Ela" })).Content.ReadFromJsonAsync<ChildBody>())!;
        var url = $"/api/v1/families/{family.Id}/habits";

        var added = await owner.PostAsJsonAsync(url, new { childId = child.Id, title = " Diş fırçalama " });
        added.StatusCode.Should().Be(HttpStatusCode.Created);
        var habit = (await added.Content.ReadFromJsonAsync<HabitsBody>())!.Habits.Single();
        habit.Title.Should().Be("Diş fırçalama");
        habit.LastSeven.Should().HaveCount(7).And.OnlyContain(d => d == false);

        var today = (await owner.GetFromJsonAsync<HabitsBody>(url))!.Today;
        await owner.PostAsJsonAsync($"{url}/{habit.Id}/check", new { day = today.AddDays(-1) });
        await owner.PostAsJsonAsync($"{url}/{habit.Id}/check", new { });
        var list = (await (await owner.PostAsJsonAsync($"{url}/{habit.Id}/check", new { })).Content.ReadFromJsonAsync<HabitsBody>())!;
        var h = list.Habits.Single();
        h.DoneToday.Should().BeTrue();
        h.Streak.Should().Be(2, "a second tap on the same day counts once");
        h.LastSeven[^1].Should().BeTrue();
        h.LastSeven[^2].Should().BeTrue();

        (await owner.PostAsJsonAsync($"{url}/{habit.Id}/check", new { day = today.AddDays(-7) })).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
        (await owner.PostAsJsonAsync($"{url}/{habit.Id}/check", new { day = today.AddDays(1) })).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);

        var unchecked_ = (await (await owner.DeleteAsync($"{url}/{habit.Id}/check?day={today.AddDays(-1):yyyy-MM-dd}")).Content.ReadFromJsonAsync<HabitsBody>())!;
        unchecked_.Habits.Single().Streak.Should().Be(1);

        (await owner.PostAsJsonAsync(url, new { childId = child.Id, title = "x", days = 0 })).StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await (await owner.DeleteAsync($"{url}/{habit.Id}")).Content.ReadFromJsonAsync<HabitsBody>())!.Habits.Should().BeEmpty();
    }
}
