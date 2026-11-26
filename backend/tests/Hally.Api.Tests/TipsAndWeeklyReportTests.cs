using System.Net;
using System.Net.Http.Json;
using FluentAssertions;
using Hally.Api.Features.Summary;
using Hally.Api.Features.Tips;
using Hally.Domain.Common;
using Hally.Domain.Notifications;
using Hally.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;

namespace Hally.Api.Tests;

public record TipBody(string Key, string Kind, string Emoji, string Text, string ActionLabel, string Action, Guid? ChildId, Guid? ExamId,
    int? Minutes, int? CurrentMinutes, DateOnly? RestoreOn, string? Route, string? Detail);
public record TipSettingsBody(bool Enabled, int Hidden, string ReportDay, string? ReportTime, bool CanGetReport);
public record ReportExamBody(Guid Id, string Subject, DateOnly Date, string? Outcome);
public record ReportChildBody(Guid ChildId, string FirstName, string Color, List<ReportExamBody> Exams, int StudyMinutes, int? ScreenAvgMinutes,
    int? SleepAvgMinutes, int Cherries, int Activities);
public record ReportAdultBody(Guid UserId, string FirstName, int Completed);
public record ReportNextWeekBody(DateOnly WeekStart, List<ReportUpcomingExamDto> Exams, int Events, DateOnly? BusiestDay, int BusiestCount);
public record WeeklyReportBody(int Offset, DateOnly WeekStart, DateOnly WeekEnd, int TasksDone, int TasksDonePrevious, int Events, int Exams,
    List<ReportAdultBody> Adults, int HelperCompleted, List<ReportChildBody> Children, ReportNextWeekBody NextWeek, string? Tip, bool Quiet);

[Collection(ApiCollection.Name)]
public class TipsAndWeeklyReportTests(HallyApiFactory api)
{
    private async Task<(HttpClient Parent, string F, Guid FamilyId, Guid ChildId)> FamilyAsync()
    {
        var parent = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Ayşe Yılmaz");
        var family = (await (await parent.PostIdempotentAsync("/api/v1/families", new { name = "Yılmaz" })).Content.ReadFromJsonAsync<FamilyBody>())!;
        var child = (await (await parent.PostIdempotentAsync($"/api/v1/families/{family.Id}/children", new { firstName = "Ela" })).Content.ReadFromJsonAsync<ChildBody>())!;
        return (parent, $"/api/v1/families/{family.Id}", family.Id, child.Id);
    }

    private DateOnly Today() => FamilyTimeZone.LocalDate(api.Clock.GetUtcNow(), FamilyTimeZone.Default);

    [Fact]
    public async Task An_exam_week_suggests_studying_and_a_lower_screen_limit_that_comes_back_after_the_exams()
    {
        var (ayse, f, _, ela) = await FamilyAsync();
        var today = Today();
        (await ayse.PostIdempotentAsync($"{f}/exams", new { childId = ela, subject = "Matematik", date = today.AddDays(1) })).EnsureSuccessStatusCode();
        (await ayse.PostIdempotentAsync($"{f}/exams", new { childId = ela, subject = "Fen", date = today.AddDays(2) })).EnsureSuccessStatusCode();
        (await ayse.PutAsJsonAsync($"{f}/children/{ela}/screen-time/goal", new { dailyMinutes = 120 })).EnsureSuccessStatusCode();

        var tips = (await ayse.GetFromJsonAsync<List<TipBody>>($"{f}/tips"))!;
        tips.Select(t => t.Kind).Should().Equal("ExamStudy", "ExamStudy", "ExamScreen");
        tips[0].Text.Should().Be("Ela yarın Matematik sınavına giriyor, henüz çalışma kaydı yok.");
        tips[0].Action.Should().Be("startStudy");
        var screen = tips[2];
        screen.Text.Should().EndWith("2 sınava giriyor. Ekran süresini biraz azaltmak ister misin?");
        screen.ActionLabel.Should().Be("Limiti 60 dk yap");
        (screen.Minutes, screen.CurrentMinutes, screen.RestoreOn).Should().Be((60, 120, today.AddDays(3)));

        // ✕ on both study tips: gone for good, and counted under "Gizlenen ipuçları".
        foreach (var t in tips.Take(2))
        {
            (await ayse.PostAsJsonAsync($"{f}/tips/dismiss", new { key = t.Key, forever = true })).StatusCode.Should().Be(HttpStatusCode.NoContent);
        }

        (await ayse.GetFromJsonAsync<List<TipBody>>($"{f}/tips"))!.Select(t => t.Kind).Should().Equal("ExamScreen");
        (await ayse.GetFromJsonAsync<TipSettingsBody>($"{f}/tips/settings"))!.Hidden.Should().Be(2);

        // "Limiti 60 dk yap" until the exams are over.
        (await ayse.PostAsJsonAsync($"{f}/tips/screen-limit", new { childId = ela, minutes = 60, restoreOn = today.AddDays(3) })).EnsureSuccessStatusCode();
        (await ayse.GetFromJsonAsync<List<TipBody>>($"{f}/tips"))!.Should().BeEmpty("the limit is already low");
        using (var scope = api.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<HallyDbContext>();
            (await db.Children.AsNoTracking().SingleAsync(c => c.Id == ela)).DailyScreenMinutes.Should().Be(60);
            var job = scope.ServiceProvider.GetRequiredService<TipsService>();
            await job.RestoreScreenGoalsAsync(default);
            (await db.Children.AsNoTracking().SingleAsync(c => c.Id == ela)).DailyScreenMinutes.Should().Be(60, "the exams are not over yet");
        }

        api.Clock.Advance(TimeSpan.FromDays(3));
        try
        {
            using var scope = api.Services.CreateScope();
            (await scope.ServiceProvider.GetRequiredService<TipsService>().RestoreScreenGoalsAsync(default)).Should().BeGreaterThanOrEqualTo(1);
            (await scope.ServiceProvider.GetRequiredService<HallyDbContext>().Children.AsNoTracking().SingleAsync(c => c.Id == ela))
                .DailyScreenMinutes.Should().Be(120);
        }
        finally
        {
            api.Clock.Advance(TimeSpan.FromDays(-3));
        }

        // "Geri getir" brings the hidden ones back; "Sonra" hides one until tomorrow.
        (await (await ayse.DeleteAsync($"{f}/tips/dismissed")).Content.ReadFromJsonAsync<TipSettingsBody>())!.Hidden.Should().Be(0);
        var back = (await ayse.GetFromJsonAsync<List<TipBody>>($"{f}/tips"))!;
        back.Select(t => t.Kind).Should().Contain("ExamStudy");
        (await ayse.PostAsJsonAsync($"{f}/tips/dismiss", new { key = back[0].Key, forever = false })).EnsureSuccessStatusCode();
        (await ayse.GetFromJsonAsync<List<TipBody>>($"{f}/tips"))!.Should().NotContain(t => t.Key == back[0].Key);
        (await ayse.GetFromJsonAsync<TipSettingsBody>($"{f}/tips/settings"))!.Hidden.Should().Be(0, "\"Sonra\" is not hidden for good");

        // Only the member's focus areas count, and tips can be turned off.
        (await ayse.PutAsJsonAsync($"{f}/focus", new { areas = new[] { "tasks" } })).EnsureSuccessStatusCode();
        (await ayse.GetFromJsonAsync<List<TipBody>>($"{f}/tips"))!.Should().NotContain(t => t.Kind.StartsWith("Exam"));
        (await ayse.PutAsJsonAsync($"{f}/focus", new { areas = Array.Empty<string>() })).EnsureSuccessStatusCode();
        (await ayse.PutAsJsonAsync($"{f}/tips/settings", new { enabled = false, reportDay = "Sunday", reportTime = "19:00" })).EnsureSuccessStatusCode();
        (await ayse.GetFromJsonAsync<List<TipBody>>($"{f}/tips"))!.Should().BeEmpty();
    }

    [Fact]
    public async Task Overdue_tasks_and_short_sleep_give_tips()
    {
        var (ayse, f, _, ela) = await FamilyAsync();
        var now = api.Clock.GetUtcNow();
        for (var i = 1; i <= 3; i++)
        {
            await ayse.PostIdempotentAsync($"{f}/tasks", new { title = $"İş {i}", dueAt = now.AddDays(-2), allDay = false });
        }

        for (var i = 1; i <= 3; i++)
        {
            var wake = now.AddDays(-i).AddHours(-5);
            (await ayse.PostAsJsonAsync($"{f}/children/{ela}/sleep/entries", new { kind = "Night", startedAt = wake.AddHours(-7), endedAt = wake })).EnsureSuccessStatusCode();
        }

        var tips = (await ayse.GetFromJsonAsync<List<TipBody>>($"{f}/tips"))!;
        tips.Should().Contain(t => t.Kind == "Overdue" && t.Text == "3 iş gecikti. Birlikte bakalım mı?" && t.Route == "/tasks");
        tips.Should().Contain(t => t.Kind == "Sleep" && t.Text.StartsWith("Ela son 3 gece ortalama 7 sa uyudu") && t.Action == "route");
    }

    [Fact]
    public async Task The_weekly_report_sums_up_the_week_and_comes_once_on_Sunday_evening()
    {
        var (ayse, f, familyId, ela) = await FamilyAsync();
        var today = Today();
        var task = (await (await ayse.PostIdempotentAsync($"{f}/tasks", new { title = "Fatura öde" })).Content.ReadFromJsonAsync<TaskBody>())!;
        (await ayse.PostIdempotentAsync($"{f}/tasks/{task.Id}/complete", null)).EnsureSuccessStatusCode();
        (await ayse.PostIdempotentAsync($"{f}/exams", new { childId = ela, subject = "Türkçe", date = today })).EnsureSuccessStatusCode();
        var nextMonday = today.AddDays(7 - ((int)today.DayOfWeek + 6) % 7);
        (await ayse.PostIdempotentAsync($"{f}/exams", new { childId = ela, subject = "Fen", date = nextMonday })).EnsureSuccessStatusCode();
        (await ayse.PostIdempotentAsync($"{f}/exams", new { childId = ela, subject = "İngilizce", date = nextMonday.AddDays(2) })).EnsureSuccessStatusCode();

        var report = (await ayse.GetFromJsonAsync<WeeklyReportBody>($"{f}/weekly-report?offset=0"))!;
        report.WeekEnd.Should().Be(report.WeekStart.AddDays(6));
        report.TasksDone.Should().Be(1);
        report.Adults.Single().Should().Match<ReportAdultBody>(a => a.FirstName == "Ayşe" && a.Completed == 1);
        report.Children.Single().Exams.Single().Subject.Should().Be("Türkçe");
        report.NextWeek.Exams.Select(e => e.Subject).Should().Equal("Fen", "İngilizce");
        report.Tip.Should().Be("Ela gelecek hafta 2 sınava giriyor. Çalışma saatlerini şimdiden planlamak iyi olabilir.");
        report.Quiet.Should().BeFalse();
        (await ayse.GetFromJsonAsync<WeeklyReportBody>($"{f}/weekly-report?offset=-1"))!.Quiet.Should().BeTrue();

        (await ayse.GetFromJsonAsync<TipSettingsBody>($"{f}/tips/settings"))!.Should().Be(new TipSettingsBody(true, 0, "Sunday", "19:00", true));
        (await ayse.PutAsJsonAsync($"{f}/tips/settings", new { enabled = true, reportDay = "Friday", reportTime = "19:00" })).StatusCode
            .Should().Be(HttpStatusCode.UnprocessableEntity);

        // Sunday 19:05 in the family's zone.
        var local = FamilyTimeZone.ToFamilyTime(api.Clock.GetUtcNow(), FamilyTimeZone.Default);
        var sunday = DateOnly.FromDateTime(local.DateTime).AddDays((7 - (int)local.DayOfWeek) % 7);
        var target = new DateTimeOffset(sunday.ToDateTime(new TimeOnly(19, 5)), local.Offset);
        var move = target - local;
        api.Clock.Advance(move);
        try
        {
            using var scope = api.Services.CreateScope();
            var job = scope.ServiceProvider.GetRequiredService<WeeklyReportService>();
            (await job.WeeklyAsync(default)).Should().BeGreaterThanOrEqualTo(1);
            (await job.WeeklyAsync(default)).Should().Be(0, "once a week");
            var n = await scope.ServiceProvider.GetRequiredService<HallyDbContext>().Notifications
                .SingleAsync(x => x.FamilyId == familyId && x.Kind == NotificationKind.WeeklyReport);
            n.Title.Should().Be("📊 Haftanın özeti hazır");
            n.Body.Should().StartWith("1 iş bitti,").And.Contain("Ela 1 sınava girdi.").And.EndWith("Gelecek hafta 2 sınav var.");
        }
        finally
        {
            api.Clock.Advance(-move);
        }

        (await (await ayse.PutAsJsonAsync($"{f}/tips/settings", new { enabled = true, reportDay = "Monday", reportTime = (string?)null }))
            .Content.ReadFromJsonAsync<TipSettingsBody>())!.Should().Be(new TipSettingsBody(true, 0, "Monday", null, true));
    }
}
