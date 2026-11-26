using System.Net;
using System.Net.Http.Json;
using FluentAssertions;
using Hally.Api.Features.Exams;
using Hally.Domain.Common;
using Hally.Domain.Notifications;
using Hally.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;

namespace Hally.Api.Tests;

public record ExamBody(Guid Id, Guid ChildId, string ChildName, string Subject, string? Topics, DateOnly Date, string? Slot, int? StudyDaysBefore, Guid? EventId,
    int DaysLeft, int StudySeconds, string? Outcome, int? Score, int Cherries, bool StudyDay);
public record ExamEventBody(Guid Id, string Title, DateTimeOffset StartsAt, bool AllDay, List<Guid> ChildIds, Guid? ExamId);
public record ChildExamBody(Guid Id, string Subject, string? Topics, DateOnly Date, string? Slot, int DaysLeft, int StudySeconds, string State);
public record ChildHomeExamsBody(int Balance, List<ChildExamBody>? Exams);

[Collection(ApiCollection.Name)]
public class ExamTests(HallyApiFactory api)
{
    /// <summary>A zone where it is 20:00-20:59 right now, so the evening notes are due.</summary>
    private string EveningZone()
    {
        var hour = api.Clock.GetUtcNow().UtcDateTime.Hour;
        var offset = 20 - hour;
        if (offset < -12)
        {
            offset += 24;
        }

        if (offset > 14)
        {
            offset -= 24;
        }

        return offset == 0 ? "Etc/UTC" : $"Etc/GMT{(offset > 0 ? "-" : "+")}{Math.Abs(offset)}";
    }

    private async Task<(HttpClient Parent, string F, Guid FamilyId, Guid ChildId, string Zone)> FamilyAsync(string? zone = null)
    {
        zone ??= TestZones.Daytime(api.Clock);
        var parent = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Ayşe");
        var family = (await (await parent.PostIdempotentAsync("/api/v1/families", new { name = "Yılmaz", timeZoneId = zone })).Content.ReadFromJsonAsync<FamilyBody>())!;
        var child = (await (await parent.PostIdempotentAsync($"/api/v1/families/{family.Id}/children", new { firstName = "Ela" })).Content.ReadFromJsonAsync<ChildBody>())!;
        return (parent, $"/api/v1/families/{family.Id}", family.Id, child.Id, zone);
    }

    private DateOnly Today(string zone) => FamilyTimeZone.LocalDate(api.Clock.GetUtcNow(), zone);

    [Fact]
    public void Exam_titles_from_a_scanned_note_give_the_subject()
    {
        ExamTexts.SubjectOf("Matematik sınavı").Should().Be("Matematik");
        ExamTexts.SubjectOf("📝 Fen Bilimleri sınavı").Should().Be("Fen Bilimleri");
        ExamTexts.SubjectOf("İngilizce yazılısı").Should().Be("İngilizce");
        ExamTexts.SubjectOf("算数のテスト").Should().Be("算数");
        ExamTexts.SubjectOf("漢字の小テスト").Should().Be("漢字");
        ExamTexts.SubjectOf("Science exam").Should().Be("Science");
        ExamTexts.SubjectOf("Veli toplantısı").Should().BeNull();
    }

    [Fact]
    public async Task An_exam_puts_one_tagged_event_in_the_calendar_and_follows_its_changes()
    {
        var (parent, f, _, childId, zone) = await FamilyAsync();
        var today = Today(zone);
        var created = await parent.PostAsJsonAsync($"{f}/exams", new { childId, subject = "Matematik", topics = "Kesirler", date = today.AddDays(2), slot = "2. ders", studyDaysBefore = 3 });
        created.StatusCode.Should().Be(HttpStatusCode.Created);
        var exam = (await created.Content.ReadFromJsonAsync<ExamBody>())!;
        exam.DaysLeft.Should().Be(2);
        exam.StudyDay.Should().BeTrue("3 days before up to the day before");
        exam.ChildName.Should().Be("Ela");

        var from = api.Clock.GetUtcNow().AddDays(-1);
        var events = (await parent.GetFromJsonAsync<List<ExamEventBody>>($"{f}/events?from={Uri.EscapeDataString(from.ToString("O"))}&to={Uri.EscapeDataString(from.AddDays(10).ToString("O"))}"))!;
        var evt = events.Single(e => e.Id == exam.EventId);
        evt.Title.Should().Be("📝 Matematik sınavı");
        evt.AllDay.Should().BeTrue("\"2. ders\" is not a clock time");
        evt.ChildIds.Should().Equal(childId);
        evt.ExamId.Should().Be(exam.Id);

        // A clock time makes a timed event; moving the date moves it.
        var moved = (await (await parent.PutAsJsonAsync($"{f}/exams/{exam.Id}", new { childId, subject = "Matematik", date = today.AddDays(5), slot = "10:30", studyDaysBefore = (int?)null }))
            .Content.ReadFromJsonAsync<ExamBody>())!;
        moved.EventId.Should().Be(exam.EventId);
        moved.StudyDay.Should().BeFalse();
        events = (await parent.GetFromJsonAsync<List<ExamEventBody>>($"{f}/events?from={Uri.EscapeDataString(from.ToString("O"))}&to={Uri.EscapeDataString(from.AddDays(10).ToString("O"))}"))!;
        evt = events.Single(e => e.Id == exam.EventId);
        evt.AllDay.Should().BeFalse();
        FamilyTimeZone.ToFamilyTime(evt.StartsAt, zone).ToString("yyyy-MM-dd HH:mm").Should().Be($"{today.AddDays(5):yyyy-MM-dd} 10:30");

        (await parent.PutAsJsonAsync($"{f}/exams/{exam.Id}", new { childId, subject = "Matematik", date = today, studyDaysBefore = 5 }))
            .StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await parent.PutAsJsonAsync($"{f}/exams/{exam.Id}/result", new { outcome = "Great" })).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity, "not yet");

        // Deleting the calendar event deletes the exam with it.
        (await parent.DeleteAsync($"{f}/events/{exam.EventId}")).StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await parent.GetFromJsonAsync<List<ExamBody>>($"{f}/exams"))!.Should().BeEmpty();
    }

    [Fact]
    public async Task Study_time_adds_up_on_the_exam_and_the_result_gives_cherries_once_for_parents_only()
    {
        var (parent, f, familyId, childId, zone) = await FamilyAsync();
        var today = Today(zone);
        var exam = (await (await parent.PostAsJsonAsync($"{f}/exams", new { childId, subject = "Türkçe", date = today, studyDaysBefore = 3 }))
            .Content.ReadFromJsonAsync<ExamBody>())!;
        await parent.PostAsJsonAsync($"{f}/children/{childId}/study/entries", new { kind = "Homework", minutes = 20, examId = exam.Id });
        var started = (await (await parent.PostAsJsonAsync($"{f}/children/{childId}/study/start", new { kind = "Homework", examId = exam.Id }))
            .Content.ReadFromJsonAsync<ChildStudyBody>())!;
        started.RunningSince.Should().NotBeNull();
        await parent.PostAsJsonAsync($"{f}/children/{childId}/study/stop", new { });
        (await parent.GetFromJsonAsync<ExamBody>($"{f}/exams/{exam.Id}"))!.StudySeconds.Should().BeGreaterThanOrEqualTo(1200);

        var result = (await (await parent.PutAsJsonAsync($"{f}/exams/{exam.Id}/result", new { outcome = "Great", score = 92, cherries = 5 }))
            .Content.ReadFromJsonAsync<ExamBody>())!;
        (result.Outcome, result.Score, result.Cherries).Should().Be(("Great", 92, 5));
        result = (await (await parent.PutAsJsonAsync($"{f}/exams/{exam.Id}/result", new { outcome = "Good", score = 85, cherries = 10 }))
            .Content.ReadFromJsonAsync<ExamBody>())!;
        (result.Outcome, result.Cherries).Should().Be(("Good", 5), "cherries are given once");

        using var scope = api.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<HallyDbContext>();
        (await db.PointEntries.Where(p => p.ChildId == childId).SumAsync(p => p.Points)).Should().Be(5);

        // A caregiver sees the exam but not the result.
        var invite = (await (await parent.PostIdempotentAsync($"{f}/invitations", new { role = "caregiver" })).Content.ReadFromJsonAsync<InvitationBody>())!;
        var nanny = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Fatma");
        (await nanny.PostIdempotentAsync($"/api/v1/invitations/{invite.Token}/accept", null)).EnsureSuccessStatusCode();
        var seen = (await nanny.GetFromJsonAsync<List<ExamBody>>($"{f}/exams"))!.Single();
        (seen.Outcome, seen.Score, seen.Cherries).Should().Be((null, null, 0));
        (await nanny.PutAsJsonAsync($"{f}/exams/{exam.Id}/result", new { outcome = "Hard" })).StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await nanny.PostAsJsonAsync($"{f}/exams", new { childId, subject = "Fen", date = today })).StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }

    [Fact]
    public async Task The_child_sees_upcoming_exams_and_calismtim_waits_for_a_parent()
    {
        var (parent, f, _, childId, zone) = await FamilyAsync();
        var today = Today(zone);
        var exam = (await (await parent.PostAsJsonAsync($"{f}/exams", new { childId, subject = "Matematik", topics = "Kesirler", date = today.AddDays(2) }))
            .Content.ReadFromJsonAsync<ExamBody>())!;
        await parent.PostAsJsonAsync($"{f}/exams", new { childId, subject = "Tarih", date = today.AddDays(30) });
        var code = (await (await parent.PostAsync($"{f}/children/{childId}/pairing-code", null)).Content.ReadFromJsonAsync<PairingCodeBody>())!;
        var paired = (await (await api.CreateClient().PostAsJsonAsync("/api/v1/child/pair", new { code = code.Code })).Content.ReadFromJsonAsync<PairResultBody>())!;
        var kid = api.CreateClient();
        kid.DefaultRequestHeaders.Add("X-Hally-Child", paired.Token);

        var home = (await kid.GetFromJsonAsync<ChildHomeExamsBody>("/api/v1/child/home"))!;
        home.Exams.Should().ContainSingle("only the next two weeks").Which.Should().Be(new ChildExamBody(exam.Id, "Matematik", "Kesirler", today.AddDays(2), null, 2, 0, "Todo"));

        (await kid.PostAsync($"/api/v1/child/exams/{exam.Id}/studied", null)).StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await kid.PostAsync($"/api/v1/child/exams/{exam.Id}/studied", null)).StatusCode.Should().Be(HttpStatusCode.NoContent, "a double tap changes nothing");
        (await kid.GetFromJsonAsync<ChildHomeExamsBody>("/api/v1/child/home"))!.Exams![0].State.Should().Be("Pending");
        var claim = (await parent.GetFromJsonAsync<List<ClaimBody>>($"{f}/claims"))!.Single();
        (claim.Kind, claim.Title, claim.Cherries).Should().Be(("Study", "Matematik", 1));
        await parent.PostAsync($"{f}/claims/{claim.Id}/approve", null);
        home = (await kid.GetFromJsonAsync<ChildHomeExamsBody>("/api/v1/child/home"))!;
        home.Exams![0].State.Should().Be("Done");
        home.Balance.Should().Be(1);

        (await kid.PostAsync($"/api/v1/child/exams/{Guid.NewGuid()}/studied", null)).StatusCode.Should().Be(HttpStatusCode.NotFound);
    }

    [Fact]
    public async Task Evenings_bring_study_time_before_the_exam_and_how_did_it_go_on_the_day()
    {
        var (parent, f, familyId, childId, zone) = await FamilyAsync(EveningZone());
        var today = Today(zone);
        var soon = (await (await parent.PostAsJsonAsync($"{f}/exams", new { childId, subject = "Matematik", topics = "Kesirler", date = today.AddDays(2), studyDaysBefore = 3 }))
            .Content.ReadFromJsonAsync<ExamBody>())!;
        var now = (await (await parent.PostAsJsonAsync($"{f}/exams", new { childId, subject = "Türkçe", date = today, studyDaysBefore = 3 }))
            .Content.ReadFromJsonAsync<ExamBody>())!;
        await parent.PostAsJsonAsync($"{f}/exams", new { childId, subject = "Fen", date = today.AddDays(2), studyDaysBefore = 1 });

        using var scope = api.Services.CreateScope();
        var job = scope.ServiceProvider.GetRequiredService<ExamService>();
        await job.EveningAsync(default);
        (await job.EveningAsync(default)).Should().Be(0, "once an evening");
        var db = scope.ServiceProvider.GetRequiredService<HallyDbContext>();
        var notes = await db.Notifications.Where(n => n.FamilyId == familyId).OrderBy(n => n.Kind).ToListAsync();
        notes.Select(n => (n.Kind, n.TargetId)).Should().BeEquivalentTo(new[] { (NotificationKind.ExamStudy, (Guid?)soon.Id), (NotificationKind.ExamResult, (Guid?)now.Id) });
        notes.Single(n => n.Kind == NotificationKind.ExamStudy).Body.Should().Be("Matematik sınavına 2 gün kaldı. Konular: Kesirler. 20 dk göz atalım mı?");
        notes.Single(n => n.Kind == NotificationKind.ExamResult).Title.Should().Be("Ela: Türkçe sınavı nasıl geçti?");
    }
}
