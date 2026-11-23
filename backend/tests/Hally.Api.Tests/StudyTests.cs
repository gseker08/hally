using System.Net;
using System.Net.Http.Json;
using FluentAssertions;
using Hally.Domain.Study;

namespace Hally.Api.Tests;

public record ChildStudyBody(Guid ChildId, int? DailyGoalMinutes, int TodaySeconds, int HomeworkSeconds, int ReadingSeconds, string? RunningKind,
    DateTimeOffset? RunningSince, DateTimeOffset? RunningUntil, string? StartedByName, int Streak, DateTimeOffset AsOf, Guid? StartedByUserId);
public record StudyDayBody(DateOnly Date, int HomeworkSeconds, int ReadingSeconds, bool GoalMet);
public record StudyEntryBody(Guid Id, string Kind, DateTimeOffset StartedAt, DateTimeOffset EndedAt, int Seconds, string? Note, string? ByName);
public record ChildStudyHistoryBody(Guid ChildId, int? DailyGoalMinutes, List<StudyDayBody> Days, List<StudyEntryBody> Entries);

[Collection(ApiCollection.Name)]
public class StudyTests(HallyApiFactory api)
{
    private async Task<(HttpClient Owner, HttpClient Partner, Guid FamilyId, Guid ChildId)> FamilyWithChild()
    {
        var owner = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Ayşe");
        var family = (await (await owner.PostIdempotentAsync("/api/v1/families", new { name = "Yılmaz" })).Content.ReadFromJsonAsync<FamilyBody>())!;
        var invite = (await (await owner.PostIdempotentAsync($"/api/v1/families/{family.Id}/invitations", null)).Content.ReadFromJsonAsync<InvitationBody>())!;
        var partner = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Mehmet", locale: "en");
        await partner.PostIdempotentAsync($"/api/v1/invitations/{invite.Token}/accept", null);
        var child = (await (await owner.PostIdempotentAsync($"/api/v1/families/{family.Id}/children", new { firstName = "Ela" })).Content.ReadFromJsonAsync<ChildBody>())!;
        return (owner, partner, family.Id, child.Id);
    }

    [Fact]
    public void Streak_counts_met_days_back_from_today_and_an_unfinished_today_does_not_break_it()
    {
        StudySession.Streak([true, true, true]).Should().Be(3);
        StudySession.Streak([true, true, false]).Should().Be(2, "today is not over");
        StudySession.Streak([true, false, true, true]).Should().Be(2);
        StudySession.Streak([false, false]).Should().Be(0);
    }

    [Fact]
    public async Task Both_parents_share_the_timer_and_a_second_start_keeps_one()
    {
        var (owner, partner, familyId, childId) = await FamilyWithChild();
        var url = $"/api/v1/families/{familyId}/children/{childId}/study";

        var started = (await (await owner.PostAsJsonAsync($"{url}/start", new { kind = "Reading" })).Content.ReadFromJsonAsync<ChildStudyBody>())!;
        started.RunningKind.Should().Be("Reading");
        started.StartedByName.Should().Be("Ayşe");
        started.StartedByUserId.Should().Be((await owner.GetFromJsonAsync<MeBody>("/api/v1/me"))!.Id, "the app shows the lock screen timer to whoever started it");
        var again = (await (await partner.PostAsJsonAsync($"{url}/start", new { kind = "Homework" })).Content.ReadFromJsonAsync<ChildStudyBody>())!;
        again.RunningSince.Should().Be(started.RunningSince);
        again.RunningKind.Should().Be("Reading", "already running");

        var stopped = (await (await partner.PostAsJsonAsync($"{url}/stop", new { note = "Küçük Prens" })).Content.ReadFromJsonAsync<ChildStudyBody>())!;
        stopped.RunningSince.Should().BeNull();
        var history = (await owner.GetFromJsonAsync<ChildStudyHistoryBody>(url))!;
        history.Days.Should().HaveCount(7);
        history.Entries.Should().ContainSingle().Which.Note.Should().Be("Küçük Prens");
        history.Entries[0].ByName.Should().Be("Mehmet");
    }

    [Fact]
    public async Task Meeting_the_goal_notifies_both_parents_once_a_day()
    {
        var (owner, partner, familyId, childId) = await FamilyWithChild();
        var url = $"/api/v1/families/{familyId}/children/{childId}/study";
        (await owner.PutAsJsonAsync($"{url}/goal", new { dailyMinutes = 2 })).StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await (await owner.PutAsJsonAsync($"{url}/goal", new { dailyMinutes = 30 })).Content.ReadFromJsonAsync<ChildStudyBody>())!.DailyGoalMinutes.Should().Be(30);

        var half = (await (await owner.PostAsJsonAsync($"{url}/entries", new { kind = "Homework", minutes = 20 })).Content.ReadFromJsonAsync<ChildStudyBody>())!;
        half.HomeworkSeconds.Should().Be(1200);
        half.Streak.Should().Be(0);

        var done = (await (await partner.PostAsJsonAsync($"{url}/entries", new { kind = "Reading", minutes = 15 })).Content.ReadFromJsonAsync<ChildStudyBody>())!;
        done.TodaySeconds.Should().Be(2100);
        done.Streak.Should().Be(1);
        await owner.PostAsJsonAsync($"{url}/entries", new { kind = "Reading", minutes = 5 });

        var ownerInbox = (await owner.GetFromJsonAsync<InboxBody>("/api/v1/me/notifications"))!;
        ownerInbox.Items.Should().ContainSingle(n => n.Kind == "StudyGoal").Which.Title.Should().Be("Ela: günlük hedef tamam");
        var partnerInbox = (await partner.GetFromJsonAsync<InboxBody>("/api/v1/me/notifications"))!;
        partnerInbox.Items.Should().ContainSingle(n => n.Kind == "StudyGoal").Which.Body.Should().Contain("30 min");

        var history = (await owner.GetFromJsonAsync<ChildStudyHistoryBody>(url))!;
        history.Days[^1].GoalMet.Should().BeTrue();
        var deleted = (await (await owner.DeleteAsync($"{url}/{history.Entries[0].Id}")).Content.ReadFromJsonAsync<ChildStudyBody>())!;
        deleted.TodaySeconds.Should().Be(2100);
    }
}
