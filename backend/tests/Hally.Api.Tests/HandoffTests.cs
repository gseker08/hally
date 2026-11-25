using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using FluentAssertions;

namespace Hally.Api.Tests;

public record HandoffSummaryBody(int Feeds, int BottleMl, int BreastMinutes, int Solids, List<string> Foods, int SleepMinutes, List<string> Sleeps,
    List<string> Doses, int ScreenMinutes);
public record HandoffReportBody(Guid Id, Guid ChildId, string ChildName, Guid ByUserId, string ByName, DateOnly Day, HandoffSummaryBody Summary,
    List<string> Incidents, string? Note, bool HasPhoto, DateTimeOffset SentAt, DateTimeOffset? ThankedAt);
public record HandoffDraftBody(DateOnly Day, HandoffSummaryBody Summary, HandoffReportBody? Sent);

[Collection(ApiCollection.Name)]
public class HandoffTests(HallyApiFactory api)
{
    private static readonly byte[] Png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 1, 2, 3, 4];

    private static string Email() => $"{Guid.NewGuid():N}@example.com";

    [Fact]
    public async Task Caregiver_ends_the_day_and_parents_get_the_report()
    {
        var ayse = await api.SignInAsync(Email(), "Ayşe");
        var family = (await (await ayse.PostIdempotentAsync("/api/v1/families", new { name = "Yılmaz" })).Content.ReadFromJsonAsync<FamilyBody>())!;
        var f = $"/api/v1/families/{family.Id}";
        await ayse.PutAsJsonAsync("/api/v1/me/devices", new { platform = "android", token = $"tok-{Guid.NewGuid():N}" });
        var careInvite = (await (await ayse.PostIdempotentAsync($"{f}/invitations", new { role = "caregiver" })).Content.ReadFromJsonAsync<RoleInvitationBody>())!;
        var fatma = await api.SignInAsync(Email(), "Fatma Kaya");
        await fatma.PostIdempotentAsync($"/api/v1/invitations/{careInvite.Token}/accept", null);
        await fatma.PutAsJsonAsync("/api/v1/me/devices", new { platform = "android", token = $"tok-{Guid.NewGuid():N}" });
        var ela = (await (await ayse.PostIdempotentAsync($"{f}/children", new { firstName = "Ela" })).Content.ReadFromJsonAsync<ChildBody>())!;

        // The day as logged by the caregiver.
        await fatma.PostAsJsonAsync($"{f}/children/{ela.Id}/feeding", new { kind = "Solid", food = "Mercimek çorbası" });
        await fatma.PostAsJsonAsync($"{f}/children/{ela.Id}/feeding", new { kind = "Bottle", amountMl = 150 });
        var med = (await (await ayse.PostIdempotentAsync($"{f}/medications", new { childId = ela.Id, name = "Şurup", dose = "5 ml", minIntervalMinutes = 360 }))
            .Content.ReadFromJsonAsync<MedicationBody>())!;
        await fatma.PostAsJsonAsync($"{f}/medications/{med.Id}/doses", new { });

        var draft = (await fatma.GetFromJsonAsync<HandoffDraftBody>($"{f}/children/{ela.Id}/handoff/draft"))!;
        draft.Sent.Should().BeNull();
        draft.Summary.Feeds.Should().Be(2);
        draft.Summary.BottleMl.Should().Be(150);
        draft.Summary.Foods.Should().Equal("Mercimek çorbası");
        draft.Summary.Doses.Should().ContainSingle().Which.Should().StartWith("Şurup 5 ml · ");

        (await fatma.PostAsJsonAsync($"{f}/children/{ela.Id}/handoffs", new { incidents = new[] { "Jumped" } })).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);

        var before = api.Push.Sent.Count;
        var res = await fatma.PostAsJsonAsync($"{f}/children/{ela.Id}/handoffs",
            new { incidents = new[] { "Fall" }, note = " Parkta dizini sıyırdı, yara bandı yaptım. " });
        res.StatusCode.Should().Be(HttpStatusCode.OK);
        var report = (await res.Content.ReadFromJsonAsync<HandoffReportBody>())!;
        report.Incidents.Should().Equal("Fall");
        report.Note.Should().Be("Parkta dizini sıyırdı, yara bandı yaptım.");
        report.ByName.Should().Be("Fatma Kaya");
        var push = api.Push.Sent.Skip(before).Should().ContainSingle().Which.Message;
        push.Title.Should().Be("Fatma günü bitirdi");
        push.Body.Should().Be("Ela · Olay: küçük düşme");
        push.Data["kind"].Should().Be("HandoffReport");

        // Photo, readable by the parent.
        var form = new MultipartFormDataContent();
        var file = new ByteArrayContent(Png);
        file.Headers.ContentType = new MediaTypeHeaderValue("image/png");
        form.Add(file, "file", "dizi.png");
        (await (await fatma.PostAsync($"{f}/handoffs/{report.Id}/photo", form)).Content.ReadFromJsonAsync<HandoffReportBody>())!.HasPhoto.Should().BeTrue();
        (await (await ayse.GetAsync($"{f}/handoffs/{report.Id}/photo")).Content.ReadAsByteArrayAsync()).Should().Equal(Png);

        // Sending again replaces the report instead of adding a second one.
        await fatma.PostAsJsonAsync($"{f}/children/{ela.Id}/handoffs", new { incidents = Array.Empty<string>(), note = "Her şey yolunda." });
        var today = (await ayse.GetFromJsonAsync<List<HandoffReportBody>>($"{f}/handoffs?day={draft.Day:yyyy-MM-dd}"))!;
        today.Should().ContainSingle().Which.Incidents.Should().BeEmpty();
        (await fatma.GetFromJsonAsync<HandoffDraftBody>($"{f}/children/{ela.Id}/handoff/draft"))!.Sent!.Note.Should().Be("Her şey yolunda.");

        before = api.Push.Sent.Count;
        var thanked = (await (await ayse.PostAsync($"{f}/handoffs/{report.Id}/thanks", null)).Content.ReadFromJsonAsync<HandoffReportBody>())!;
        thanked.ThankedAt.Should().NotBeNull();
        api.Push.Sent.Skip(before).Should().ContainSingle().Which.Message.Title.Should().Be("Ayşe teşekkür etti 💛");
        (await fatma.PostAsync($"{f}/handoffs/{report.Id}/thanks", null)).StatusCode.Should().Be(HttpStatusCode.Forbidden, "only parents say thanks");

        (await fatma.GetFromJsonAsync<List<HandoffReportBody>>($"{f}/handoffs?childId={ela.Id}"))!.Should().ContainSingle();
    }
}
