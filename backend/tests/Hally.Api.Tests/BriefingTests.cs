using System.Net;
using System.Net.Http.Json;
using FluentAssertions;
using Hally.Api.Features.Briefing;
using Hally.Domain.Common;
using Hally.Domain.Notifications;
using Hally.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;

namespace Hally.Api.Tests;

public record BriefingLineBody(string Kind, string Emoji, string Text);
public record BriefingBody(string Day, DateOnly Date, string Greeting, List<BriefingLineBody> Lines, string Speech, string ShortSpeech);
public record BriefingSettingsBody(string? Time);

[Collection(ApiCollection.Name)]
public class BriefingTests(HallyApiFactory api)
{
    private static string Email() => $"{Guid.NewGuid():N}@example.com";

    private async Task<(HttpClient Ayse, string F, Guid FamilyId)> FamilyAsync()
    {
        var ayse = await api.SignInAsync(Email(), "Ayşe Yılmaz");
        var family = (await (await ayse.PostIdempotentAsync("/api/v1/families", new { name = "Yılmaz" })).Content.ReadFromJsonAsync<FamilyBody>())!;
        return (ayse, $"/api/v1/families/{family.Id}", family.Id);
    }

    [Fact]
    public async Task Bugun_ne_var_reads_the_events_the_school_run_and_the_tasks_without_any_AI()
    {
        var (ayse, f, _) = await FamilyAsync();
        var now = api.Clock.GetUtcNow();
        var local = FamilyTimeZone.ToFamilyTime(now, FamilyTimeZone.Default);
        var weekday = ((int)local.DayOfWeek + 6) % 7;
        var me = (await ayse.GetFromJsonAsync<DutyWeekBody>($"{f}/duties"))!.Adults.Single().UserId;
        (await ayse.PutAsJsonAsync($"{f}/duties/rules/{weekday}/DropOff", new { assigneeUserId = me, time = "08:15:00" })).EnsureSuccessStatusCode();
        await ayse.PostIdempotentAsync($"{f}/events", new { title = "Yüzme", startsAt = now.AddHours(3), endsAt = now.AddHours(4), allDay = false });
        await ayse.PostIdempotentAsync($"{f}/events", new { title = "Doktor", startsAt = now.AddDays(1), endsAt = now.AddDays(1).AddHours(1), allDay = false });
        await ayse.PostIdempotentAsync($"{f}/tasks", new { title = "Fatura öde", dueAt = now.AddDays(-1), allDay = false });
        await ayse.PostIdempotentAsync($"{f}/tasks", new { title = "Ekmek al", dueAt = now.AddHours(2), allDay = false });

        var today = (await ayse.GetFromJsonAsync<BriefingBody>($"{f}/briefing"))!;
        today.Day.Should().Be("today");
        today.Greeting.Should().StartWith("İyi günler Ayşe!").And.Contain("Bugün");
        today.Lines.Select(l => l.Kind).Should().Equal("Event", "DropOff", "Tasks");
        today.Lines[0].Text.Should().EndWith("Yüzme");
        today.Lines[1].Text.Should().Be("Okula bırakma: Ayşe, 08:15");
        today.Lines[2].Text.Should().Be("2 iş var, biri gecikmiş: Fatura öde");
        today.Speech.Should().NotContain("📅").And.Contain("Yüzme").And.Contain("Fatura öde");
        today.ShortSpeech.Should().EndWith("1 etkinlik ve 2 iş var.");

        var tomorrow = (await ayse.GetFromJsonAsync<BriefingBody>($"{f}/briefing?day=tomorrow&lang=en"))!;
        tomorrow.Date.Should().Be(DateOnly.FromDateTime(local.DateTime).AddDays(1));
        tomorrow.Greeting.Should().Contain("Tomorrow is");
        tomorrow.Lines.Should().Contain(l => l.Kind == "Event" && l.Text.EndsWith("Doktor"));
        tomorrow.Lines.Should().NotContain(l => l.Kind == "Tasks", "overdue tasks belong to today");
    }

    [Fact]
    public async Task An_empty_day_says_so_and_the_morning_notification_comes_once_at_the_chosen_time()
    {
        var (ayse, f, familyId) = await FamilyAsync();
        (await ayse.GetFromJsonAsync<BriefingBody>($"{f}/briefing"))!.Lines.Should().ContainSingle(l => l.Kind == "Empty");

        (await ayse.PutAsJsonAsync($"{f}/briefing/settings", new { time = "04:00" })).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
        (await ayse.PutAsJsonAsync($"{f}/briefing/settings", new { time = "7:3" })).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
        (await (await ayse.PutAsJsonAsync($"{f}/briefing/settings", new { time = "07:30" })).Content.ReadFromJsonAsync<BriefingSettingsBody>())!.Time.Should().Be("07:30");
        (await ayse.GetFromJsonAsync<BriefingSettingsBody>($"{f}/briefing/settings"))!.Time.Should().Be("07:30");

        var back = TimeSpan.FromHours(4.5) - TimeSpan.FromMinutes(5);
        api.Clock.Advance(-back); // 07:35 in the family's zone
        try
        {
            using var scope = api.Services.CreateScope();
            var job = scope.ServiceProvider.GetRequiredService<BriefingService>();
            (await job.MorningAsync(default)).Should().BeGreaterThanOrEqualTo(1);
            (await job.MorningAsync(default)).Should().Be(0, "once a day");
            var db = scope.ServiceProvider.GetRequiredService<HallyDbContext>();
            var n = await db.Notifications.SingleAsync(x => x.FamilyId == familyId && x.Kind == NotificationKind.MorningBriefing);
            n.Title.Should().Be("☀️ Günaydın! Bugünün özeti");
            n.Body.Should().Be("🙂 Bugün takvim boş, rahat bir gün.");
        }
        finally
        {
            api.Clock.Advance(back);
        }

        (await (await ayse.PutAsJsonAsync($"{f}/briefing/settings", new { time = (string?)null })).Content.ReadFromJsonAsync<BriefingSettingsBody>())!.Time.Should().BeNull();
    }
}
