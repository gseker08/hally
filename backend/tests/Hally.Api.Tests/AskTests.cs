using System.Net;
using System.Net.Http.Json;
using FluentAssertions;
using Hally.Domain.Notifications;
using Hally.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;

namespace Hally.Api.Tests;

public record AskPresetBody(Guid? Id, string Emoji, string Title, string? Question, List<string> Options, int? ScreenMinutes);
public record AskBody(Guid Id, Guid ChildId, string ChildName, string Emoji, string Title, string? Detail, int? ScreenMinutes, string Status, string? Note,
    string? AnsweredByName, DateTimeOffset? AnsweredAt, DateTimeOffset CreatedAt);
public record ChildAsksBody(List<AskPresetBody> Presets, List<AskBody> Asks);

[Collection(ApiCollection.Name)]
public class AskTests(HallyApiFactory api)
{
    private static string Email() => $"{Guid.NewGuid():N}@example.com";

    private async Task<(HttpClient Ayse, HttpClient Mehmet, HttpClient Zeynep, string F, Guid ChildId, HttpClient Kid, string AyseToken, string MehmetToken)> FamilyAsync()
    {
        var ayse = await api.SignInAsync(Email(), "Ayşe Yılmaz");
        var family = (await (await ayse.PostIdempotentAsync("/api/v1/families", new { name = "Yılmaz" })).Content.ReadFromJsonAsync<FamilyBody>())!;
        var f = $"/api/v1/families/{family.Id}";
        var invite = (await (await ayse.PostIdempotentAsync($"{f}/invitations", null)).Content.ReadFromJsonAsync<InvitationBody>())!;
        var mehmet = await api.SignInAsync(Email(), "Mehmet");
        await mehmet.PostIdempotentAsync($"/api/v1/invitations/{invite.Token}/accept", null);
        var careInvite = (await (await ayse.PostIdempotentAsync($"{f}/invitations", new { role = "caregiver" })).Content.ReadFromJsonAsync<RoleInvitationBody>())!;
        var zeynep = await api.SignInAsync(Email(), "Zeynep");
        await zeynep.PostIdempotentAsync($"/api/v1/invitations/{careInvite.Token}/accept", null);
        var ayseToken = $"tok-{Guid.NewGuid():N}";
        var mehmetToken = $"tok-{Guid.NewGuid():N}";
        await ayse.PutAsJsonAsync("/api/v1/me/devices", new { platform = "android", token = ayseToken });
        await mehmet.PutAsJsonAsync("/api/v1/me/devices", new { platform = "android", token = mehmetToken });

        var child = (await (await ayse.PostIdempotentAsync($"{f}/children", new { firstName = "Ela" })).Content.ReadFromJsonAsync<ChildBody>())!;
        var code = (await (await ayse.PostAsync($"{f}/children/{child.Id}/pairing-code", null)).Content.ReadFromJsonAsync<PairingCodeBody>())!;
        var paired = (await (await api.CreateClient().PostAsJsonAsync("/api/v1/child/pair", new { code = code.Code })).Content.ReadFromJsonAsync<PairResultBody>())!;
        var kid = api.CreateClient();
        kid.DefaultRequestHeaders.Add("X-Hally-Child", paired.Token);
        return (ayse, mehmet, zeynep, f, child.Id, kid, ayseToken, mehmetToken);
    }

    [Fact]
    public async Task The_child_asks_both_parents_hear_and_the_first_answer_counts()
    {
        var (ayse, mehmet, zeynep, f, childId, kid, ayseToken, mehmetToken) = await FamilyAsync();

        var page = (await kid.GetFromJsonAsync<ChildAsksBody>("/api/v1/child/asks"))!;
        page.Presets.Select(p => p.Title).Should().Equal("Arkadaşıma gidebilir miyim?", "15 dk daha oyun", "Atıştırmalık alabilir miyim?", "Çizgi film izleyebilir miyim?");
        page.Asks.Should().BeEmpty();
        var friend = page.Presets[0];
        friend.Question.Should().Be("Kimin evine?");

        var before = api.Push.Sent.Count;
        page = (await (await kid.PostAsJsonAsync("/api/v1/child/asks", new { presetId = friend.Id, detail = "Zeynep" })).Content.ReadFromJsonAsync<ChildAsksBody>())!;
        var ask = page.Asks.Should().ContainSingle().Which;
        ask.Should().Match<AskBody>(a => a.Status == "Pending" && a.Detail == "Zeynep" && a.Emoji == "🏠");

        // Both parents get Evet/Hayır (drawn by the app), the caregiver nothing.
        var pushes = api.Push.Sent.Skip(before).ToList();
        pushes.Select(p => p.Token).Should().BeEquivalentTo([ayseToken, mehmetToken]);
        pushes.Should().AllSatisfy(p =>
        {
            p.Message.Title.Should().Be("Ela bir şey istiyor");
            p.Message.Body.Should().Be("🏠 Arkadaşıma gidebilir miyim? · Zeynep");
            p.Message.AppDrawsOnAndroid.Should().BeTrue();
            p.Message.Data["askId"].Should().Be(ask.Id.ToString());
        });

        // The same request again while it waits is refused; caregivers can't see or answer.
        (await kid.PostAsJsonAsync("/api/v1/child/asks", new { presetId = friend.Id, detail = "Can" })).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
        (await zeynep.GetAsync($"{f}/asks")).StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await zeynep.PostAsJsonAsync($"{f}/asks/{ask.Id}/answer", new { yes = true })).StatusCode.Should().Be(HttpStatusCode.Forbidden);

        (await ayse.GetFromJsonAsync<List<AskBody>>($"{f}/asks"))!.Should().ContainSingle(a => a.Id == ask.Id && a.ChildName == "Ela");

        before = api.Push.Sent.Count;
        var answered = (await (await ayse.PostAsJsonAsync($"{f}/asks/{ask.Id}/answer", new { yes = true, note = "Saat 6'da evde ol 😊" })).Content.ReadFromJsonAsync<AskBody>())!;
        answered.Should().Match<AskBody>(a => a.Status == "Yes" && a.Note == "Saat 6'da evde ol 😊" && a.AnsweredByName == "Ayşe");
        var told = api.Push.Sent.Skip(before).Should().ContainSingle().Which;
        told.Token.Should().Be(mehmetToken);
        told.Message.Title.Should().Be("Ayşe onayladı");
        told.Message.Data["kind"].Should().Be("ChildAskAnswered");
        told.Message.Data["askId"].Should().Be(ask.Id.ToString());

        // Mehmet's "Hayır" from the lock screen comes second.
        var late = await mehmet.PostAsJsonAsync($"{f}/asks/{ask.Id}/answer", new { yes = false });
        late.StatusCode.Should().Be(HttpStatusCode.Conflict);
        (await late.Content.ReadAsStringAsync()).Should().Contain("ask.already_answered").And.Contain("Ayşe");

        // The child sees the answer and the note.
        var mine = (await kid.GetFromJsonAsync<ChildAsksBody>("/api/v1/child/asks"))!.Asks.Single();
        mine.Should().Match<AskBody>(a => a.Status == "Yes" && a.Note == "Saat 6'da evde ol 😊" && a.AnsweredByName == "Ayşe");

        // Answered, so the same request can be made again.
        (await kid.PostAsJsonAsync("/api/v1/child/asks", new { presetId = friend.Id, detail = "Can" })).StatusCode.Should().Be(HttpStatusCode.OK);
        (await kid.PostAsJsonAsync("/api/v1/child/asks", new { text = "  " })).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
        (await kid.PostAsJsonAsync("/api/v1/child/asks", new { text = "Bisikletle sokağa çıkabilir miyim?" })).StatusCode.Should().Be(HttpStatusCode.OK);
        (await kid.PostAsJsonAsync("/api/v1/child/asks", new { presetId = page.Presets[2].Id })).StatusCode.Should().Be(HttpStatusCode.OK);
        (await kid.PostAsJsonAsync("/api/v1/child/asks", new { presetId = page.Presets[3].Id })).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity, "three are already waiting");
        _ = childId;
    }

    [Fact]
    public async Task A_yes_to_more_game_time_really_opens_the_lock()
    {
        var (ayse, _, _, f, childId, kid, _, _) = await FamilyAsync();
        await ayse.PutAsJsonAsync($"{f}/children/{childId}/screen-time/goal", new { dailyMinutes = 30 });
        (await (await kid.PostAsJsonAsync("/api/v1/child/screen", new { usedSeconds = 31 * 60 })).Content.ReadFromJsonAsync<ChildScreenStatusBody>())!.Locked.Should().BeTrue();

        var game = (await kid.GetFromJsonAsync<ChildAsksBody>("/api/v1/child/asks"))!.Presets.Single(p => p.ScreenMinutes == 15);
        var ask = (await (await kid.PostAsJsonAsync("/api/v1/child/asks", new { presetId = game.Id })).Content.ReadFromJsonAsync<ChildAsksBody>())!.Asks.Single();
        await ayse.PostAsJsonAsync($"{f}/asks/{ask.Id}/answer", new { yes = true });

        var screen = (await kid.GetFromJsonAsync<ChildScreenStatusBody>("/api/v1/child/screen"))!;
        screen.Should().Match<ChildScreenStatusBody>(s => s.BonusMinutes == 15 && s.LimitMinutes == 45 && !s.Locked);

        // The lock screen's "15 dk daha iste" is a request too; asking twice while it waits sends one.
        await kid.PostAsJsonAsync("/api/v1/child/screen", new { usedSeconds = 46 * 60 });
        await kid.PostAsJsonAsync("/api/v1/child/screen/request", new { minutes = 15 });
        await kid.PostAsJsonAsync("/api/v1/child/screen/request", new { minutes = 15 });
        var open = (await ayse.GetFromJsonAsync<List<AskBody>>($"{f}/asks"))!.Where(a => a.Status == "Pending").ToList();
        open.Should().ContainSingle().Which.Title.Should().Be("15 dk daha ekran");
        await ayse.PostAsJsonAsync($"{f}/asks/{open[0].Id}/answer", new { yes = false, note = "Yarın" });
        (await kid.GetFromJsonAsync<ChildScreenStatusBody>("/api/v1/child/screen"))!.Locked.Should().BeTrue("a no adds nothing");
    }

    [Fact]
    public async Task Parents_edit_the_ready_made_requests()
    {
        var (ayse, _, zeynep, f, _, kid, _, _) = await FamilyAsync();
        var presets = (await ayse.GetFromJsonAsync<List<AskPresetBody>>($"{f}/ask-presets"))!;
        presets.Should().HaveCount(4);
        (await zeynep.GetAsync($"{f}/ask-presets")).StatusCode.Should().Be(HttpStatusCode.Forbidden);

        var friend = presets[0] with { Options = ["Zeynep", "Can"] };
        var list = new object[]
        {
            friend,
            new { emoji = "🚲", title = "Bisiklete binebilir miyim?", question = (string?)null, options = Array.Empty<string>(), screenMinutes = (int?)null },
            presets[1],
        };
        var saved = (await (await ayse.PutAsJsonAsync($"{f}/ask-presets", new { presets = list })).Content.ReadFromJsonAsync<List<AskPresetBody>>())!;
        saved.Select(p => p.Title).Should().Equal("Arkadaşıma gidebilir miyim?", "Bisiklete binebilir miyim?", "15 dk daha oyun");
        saved[0].Id.Should().Be(friend.Id);
        saved[0].Options.Should().Equal("Zeynep", "Can");
        (await kid.GetFromJsonAsync<ChildAsksBody>("/api/v1/child/asks"))!.Presets.Should().HaveCount(3);

        (await ayse.PutAsJsonAsync($"{f}/ask-presets", new { presets = new[] { new { emoji = "🎮", title = "Oyun", screenMinutes = 500 } } })).StatusCode
            .Should().Be(HttpStatusCode.UnprocessableEntity);

        // An emptied list stays empty: no defaults again.
        await ayse.PutAsJsonAsync($"{f}/ask-presets", new { presets = Array.Empty<object>() });
        (await kid.GetFromJsonAsync<ChildAsksBody>("/api/v1/child/asks"))!.Presets.Should().BeEmpty();
    }

    [Fact]
    public async Task Old_requests_expire_and_are_deleted_after_90_days()
    {
        var (ayse, _, _, f, childId, kid, _, _) = await FamilyAsync();
        var ask = (await (await kid.PostAsJsonAsync("/api/v1/child/asks", new { text = "Dondurma?" })).Content.ReadFromJsonAsync<ChildAsksBody>())!.Asks.Single();
        using (var scope = api.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<HallyDbContext>();
            var day = DateOnly.FromDateTime(api.Clock.GetUtcNow().UtcDateTime);
            await db.ChildAsks.Where(a => a.Id == ask.Id).ExecuteUpdateAsync(s => s.SetProperty(a => a.Day, day.AddDays(-1)));
        }

        (await ayse.GetFromJsonAsync<List<AskBody>>($"{f}/asks"))!.Single(a => a.Id == ask.Id).Status.Should().Be("Expired");
        (await ayse.PostAsJsonAsync($"{f}/asks/{ask.Id}/answer", new { yes = true })).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);

        using (var scope = api.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<HallyDbContext>();
            var day = DateOnly.FromDateTime(api.Clock.GetUtcNow().UtcDateTime);
            await db.ChildAsks.Where(a => a.Id == ask.Id).ExecuteUpdateAsync(s => s.SetProperty(a => a.Day, day.AddDays(-91)));
            await scope.ServiceProvider.GetRequiredService<Hally.Api.Features.Notifications.RetentionJob>().RunAsync(CancellationToken.None);
            (await db.ChildAsks.AnyAsync(a => a.Id == ask.Id)).Should().BeFalse();
            (await db.Notifications.AnyAsync(n => n.Kind == NotificationKind.ChildAsk && n.TargetId == ask.Id)).Should().BeTrue("inbox entries follow their own 90 days");
        }

        _ = childId;
    }
}
