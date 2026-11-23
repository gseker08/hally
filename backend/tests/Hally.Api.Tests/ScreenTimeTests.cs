using System.Net;
using System.Net.Http.Json;
using System.Text.Json.Serialization;
using FluentAssertions;
using Hally.Api.Features.ScreenTime;
using Microsoft.AspNetCore.Http.Connections;
using Microsoft.AspNetCore.SignalR.Client;
using Microsoft.Extensions.DependencyInjection;

namespace Hally.Api.Tests;

public record ChildScreenBody(Guid ChildId, int? DailyGoalMinutes, int TodaySeconds, DateTimeOffset? RunningSince, DateTimeOffset? RunningUntil,
    Guid? StartedByUserId, string? StartedByName, DateTimeOffset AsOf);
public record ScreenTodayBody(DateOnly Date, List<ChildScreenBody> Children);
public record ChildScreenWeekBody(Guid ChildId, int? DailyGoalMinutes, List<int> DailySeconds, int TotalSeconds, int AverageSeconds, int DaysOverGoal);
public record ScreenWeekBody(DateOnly Start, DateOnly End, List<ChildScreenWeekBody> Children);
public record ScreenTimeEventBody(Guid FamilyId, ChildScreenBody Status);

[Collection(ApiCollection.Name)]
public class ScreenTimeTests(HallyApiFactory api)
{
    private async Task<(HttpClient Owner, HttpClient Partner, Guid FamilyId, Guid ChildId)> FamilyWithChild()
    {
        var owner = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Ayşe");
        var family = (await (await owner.PostIdempotentAsync("/api/v1/families", new { name = "Yılmaz" })).Content.ReadFromJsonAsync<FamilyBody>())!;
        var invite = (await (await owner.PostIdempotentAsync($"/api/v1/families/{family.Id}/invitations", null)).Content.ReadFromJsonAsync<InvitationBody>())!;
        var partner = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Mehmet", "en");
        await partner.PostIdempotentAsync($"/api/v1/invitations/{invite.Token}/accept", null);
        var child = (await (await owner.PostIdempotentAsync($"/api/v1/families/{family.Id}/children", new { firstName = "Ela" })).Content.ReadFromJsonAsync<ChildBody>())!;
        return (owner, partner, family.Id, child.Id);
    }

    private static string Url(Guid familyId, Guid childId, string action) => $"/api/v1/families/{familyId}/children/{childId}/screen-time/{action}";

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
    public async Task Both_parents_see_the_same_running_timer_and_a_second_start_does_not_double_count()
    {
        var (owner, partner, familyId, childId) = await FamilyWithChild();

        var started = (await (await owner.PostAsync(Url(familyId, childId, "start"), null)).Content.ReadFromJsonAsync<ChildScreenBody>())!;
        started.RunningSince.Should().NotBeNull();
        started.StartedByName.Should().Be("Ayşe");

        // The partner presses Start too: same timer, not a second one.
        var again = (await (await partner.PostAsync(Url(familyId, childId, "start"), null)).Content.ReadFromJsonAsync<ChildScreenBody>())!;
        again.RunningSince.Should().Be(started.RunningSince);

        await WithClockAdvanced(TimeSpan.FromMinutes(10), async () =>
        {
            var seenByPartner = (await partner.GetFromJsonAsync<ScreenTodayBody>($"/api/v1/families/{familyId}/screen-time"))!;
            seenByPartner.Children.Should().ContainSingle().Which.TodaySeconds.Should().BeInRange(599, 601);

            var stopped = (await (await partner.PostAsync(Url(familyId, childId, "stop"), null)).Content.ReadFromJsonAsync<ChildScreenBody>())!;
            stopped.RunningSince.Should().BeNull();
            stopped.TodaySeconds.Should().BeInRange(599, 601);
        });

        // Stopping twice is fine.
        (await owner.PostAsync(Url(familyId, childId, "stop"), null)).StatusCode.Should().Be(HttpStatusCode.OK);
    }

    [Fact]
    public async Task Reaching_the_goal_notifies_every_adult_once_in_their_language()
    {
        var (owner, partner, familyId, childId) = await FamilyWithChild();
        await partner.PutAsJsonAsync("/api/v1/me/devices", new { platform = "android", token = $"tok-{Guid.NewGuid():N}" });
        (await owner.PutAsJsonAsync(Url(familyId, childId, "goal"), new { dailyMinutes = 30 })).StatusCode.Should().Be(HttpStatusCode.OK);

        await owner.PostAsync(Url(familyId, childId, "start"), null);
        await WithClockAdvanced(TimeSpan.FromMinutes(20), async () =>
        {
            using var scope = api.Services.CreateScope();
            (await scope.ServiceProvider.GetRequiredService<ScreenTimeGoalJob>().RunAsync(default)).Should().Be(0, "20 of 30 minutes");
        });
        await WithClockAdvanced(TimeSpan.FromMinutes(31), async () =>
        {
            using (var scope = api.Services.CreateScope())
            {
                (await scope.ServiceProvider.GetRequiredService<ScreenTimeGoalJob>().RunAsync(default)).Should().Be(1);
            }

            using (var scope = api.Services.CreateScope())
            {
                (await scope.ServiceProvider.GetRequiredService<ScreenTimeGoalJob>().RunAsync(default)).Should().Be(0, "once per day");
            }

            // Stopping after the goal does not notify again either.
            await owner.PostAsync(Url(familyId, childId, "stop"), null);
        });

        var ownerInbox = (await owner.GetFromJsonAsync<InboxBody>("/api/v1/me/notifications"))!;
        ownerInbox.Items.Should().ContainSingle(n => n.Kind == "ScreenTimeGoal").Which.Title.Should().Be("Ela: ekran süresi hedefi doldu");
        var partnerInbox = (await partner.GetFromJsonAsync<InboxBody>("/api/v1/me/notifications"))!;
        var note = partnerInbox.Items.Should().ContainSingle(n => n.Kind == "ScreenTimeGoal").Subject;
        note.Title.Should().Be("Ela: screen time goal reached");
        note.Body.Should().Contain("30 min");
        api.Push.Sent.Should().Contain(p => p.Message.Title == "Ela: screen time goal reached");
    }

    [Fact]
    public async Task Manual_minutes_count_toward_the_week_and_days_over_goal()
    {
        var (owner, _, familyId, childId) = await FamilyWithChild();
        await owner.PutAsJsonAsync(Url(familyId, childId, "goal"), new { dailyMinutes = 60 });
        var res = await owner.PostAsJsonAsync(Url(familyId, childId, "entries"), new { minutes = 90 });
        res.StatusCode.Should().Be(HttpStatusCode.OK);
        (await res.Content.ReadFromJsonAsync<ChildScreenBody>())!.TodaySeconds.Should().BeGreaterThanOrEqualTo(90 * 60 - 1);

        var week = (await owner.GetFromJsonAsync<ScreenWeekBody>($"/api/v1/families/{familyId}/screen-time/week"))!;
        week.Start.DayOfWeek.Should().Be(DayOfWeek.Monday);
        var child = week.Children.Should().ContainSingle().Subject;
        child.DailySeconds.Should().HaveCount(7);
        child.TotalSeconds.Should().Be(90 * 60);
        child.DaysOverGoal.Should().Be(1);

        (await owner.PostAsJsonAsync(Url(familyId, childId, "entries"), new { minutes = 0 })).StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await owner.PutAsJsonAsync(Url(familyId, childId, "goal"), new { dailyMinutes = 2 })).StatusCode.Should().Be(HttpStatusCode.BadRequest);
    }

    [Fact]
    public async Task A_forgotten_timer_stops_counting_after_eight_hours()
    {
        var (owner, _, familyId, childId) = await FamilyWithChild();
        await owner.PostAsync(Url(familyId, childId, "start"), null);
        await WithClockAdvanced(TimeSpan.FromHours(9), async () =>
        {
            using (var scope = api.Services.CreateScope())
            {
                await scope.ServiceProvider.GetRequiredService<ScreenTimeGoalJob>().RunAsync(default);
            }

            var today = (await owner.GetFromJsonAsync<ScreenTodayBody>($"/api/v1/families/{familyId}/screen-time"))!;
            today.Children.Single().RunningSince.Should().BeNull("the job closed it");
        });
    }

    [Fact]
    public async Task Other_families_cannot_touch_the_timer()
    {
        var (_, _, familyId, childId) = await FamilyWithChild();
        var stranger = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Yabancı");
        (await stranger.PostAsync(Url(familyId, childId, "start"), null)).StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await stranger.GetAsync($"/api/v1/families/{familyId}/screen-time")).StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }

    [Fact]
    public async Task Start_is_announced_live_to_the_other_parent()
    {
        var (owner, partner, familyId, childId) = await FamilyWithChild();
        var received = new List<ScreenTimeEventBody>();
        var token = partner.DefaultRequestHeaders.Authorization!.Parameter;
        await using var connection = new HubConnectionBuilder()
            .WithUrl(new Uri(api.Server.BaseAddress, "hubs/chat"), o =>
            {
                o.Transports = HttpTransportType.LongPolling;
                o.HttpMessageHandlerFactory = _ => api.Server.CreateHandler();
                o.AccessTokenProvider = () => Task.FromResult(token);
            })
            .AddJsonProtocol(o => o.PayloadSerializerOptions.Converters.Add(new JsonStringEnumConverter()))
            .Build();
        connection.On<ScreenTimeEventBody>("ScreenTimeChanged", e =>
        {
            lock (received)
            {
                received.Add(e);
            }
        });
        await connection.StartAsync();

        await owner.PostAsync(Url(familyId, childId, "start"), null);

        for (var i = 0; i < 50 && received.Count == 0; i++)
        {
            await Task.Delay(100);
        }

        received.Should().ContainSingle();
        received[0].FamilyId.Should().Be(familyId);
        received[0].Status.ChildId.Should().Be(childId);
        received[0].Status.RunningSince.Should().NotBeNull();
    }
}
