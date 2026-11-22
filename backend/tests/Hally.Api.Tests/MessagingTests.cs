using System.Net;
using System.Net.Http.Json;
using FluentAssertions;

namespace Hally.Api.Tests;

public record MessageBody(Guid Id, Guid SenderUserId, string? SenderName, string Body, DateTimeOffset CreatedAt, Guid? TaskId, Guid? EventId, string? LinkTitle);
public record ChatSummaryBody(string Key, string Kind, Guid? OtherUserId, string? OtherName, MessageBody? LastMessage, int Unread);
public record ChatListBody(List<ChatSummaryBody> Chats, int TotalUnread);

[Collection(ApiCollection.Name)]
public class MessagingTests(HallyApiFactory api)
{
    private record Adult(HttpClient Client, Guid UserId);

    /// <summary>A family with Ayşe (owner), Mehmet and, when asked, Fatma (needs the trial for a third adult).</summary>
    private async Task<(Guid FamilyId, Adult Ayse, Adult Mehmet, Adult? Fatma)> Family(bool third = false)
    {
        var owner = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Ayşe Yılmaz");
        var family = (await (await owner.PostIdempotentAsync("/api/v1/families", new { name = "Aile" })).Content.ReadFromJsonAsync<FamilyBody>())!;
        if (third)
        {
            await owner.PostIdempotentAsync($"/api/v1/families/{family.Id}/subscription/trial", null);
        }

        async Task<Adult> Join(string name)
        {
            var invite = (await (await owner.PostIdempotentAsync($"/api/v1/families/{family.Id}/invitations", null)).Content.ReadFromJsonAsync<InvitationBody>())!;
            var client = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", name);
            (await client.PostIdempotentAsync($"/api/v1/invitations/{invite.Token}/accept", null)).StatusCode.Should().Be(HttpStatusCode.OK);
            return new Adult(client, (await client.GetFromJsonAsync<MeBody>("/api/v1/me"))!.Id);
        }

        var ayse = new Adult(owner, (await owner.GetFromJsonAsync<MeBody>("/api/v1/me"))!.Id);
        var mehmet = await Join("Mehmet");
        var fatma = third ? await Join("Fatma") : null;
        return (family.Id, ayse, mehmet, fatma);
    }

    private static async Task<MessageBody> Send(Adult from, Guid familyId, string key, string body, Guid? taskId = null)
    {
        var res = await from.Client.PostIdempotentAsync($"/api/v1/families/{familyId}/chats/{key}/messages", new { body, taskId });
        res.StatusCode.Should().Be(HttpStatusCode.Created);
        return (await res.Content.ReadFromJsonAsync<MessageBody>())!;
    }

    private static async Task<ChatListBody> Chats(Adult who, Guid familyId) =>
        (await who.Client.GetFromJsonAsync<ChatListBody>($"/api/v1/families/{familyId}/chats"))!;

    [Fact]
    public async Task Family_chat_is_shared_and_counts_unread_until_read()
    {
        var (familyId, ayse, mehmet, _) = await Family();
        await Send(ayse, familyId, "family", "Akşam yemeğini ben alırım");
        var second = await Send(ayse, familyId, "family", "Ekmek de alayım mı?");

        var list = await Chats(mehmet, familyId);
        list.Chats[0].Key.Should().Be("family");
        list.Chats[0].Unread.Should().Be(2);
        list.Chats[0].LastMessage!.Body.Should().Be("Ekmek de alayım mı?");
        list.Chats[0].LastMessage!.SenderName.Should().Be("Ayşe Yılmaz");
        list.TotalUnread.Should().Be(2);
        (await Chats(ayse, familyId)).TotalUnread.Should().Be(0, "your own messages are never unread");

        var messages = await mehmet.Client.GetFromJsonAsync<List<MessageBody>>($"/api/v1/families/{familyId}/chats/family/messages");
        messages!.Select(m => m.Body).Should().Equal("Akşam yemeğini ben alırım", "Ekmek de alayım mı?");
        (await mehmet.Client.PostAsync($"/api/v1/families/{familyId}/chats/family/read", null)).StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await Chats(mehmet, familyId)).TotalUnread.Should().Be(0);

        var reply = await Send(mehmet, familyId, "family", "Al lütfen");
        var since = await ayse.Client.GetFromJsonAsync<List<MessageBody>>(
            $"/api/v1/families/{familyId}/chats/family/messages?after={Uri.EscapeDataString(second.CreatedAt.ToString("O"))}");
        since!.Should().ContainSingle().Which.Id.Should().Be(reply.Id);
    }

    [Fact]
    public async Task Direct_chat_is_private_to_the_two_adults()
    {
        var (familyId, ayse, mehmet, fatma) = await Family(third: true);
        await Send(ayse, familyId, mehmet.UserId.ToString(), "Sürpriz doğum günü için ne alalım?");

        var mehmetChats = await Chats(mehmet, familyId);
        var withAyse = mehmetChats.Chats.Single(c => c.OtherUserId == ayse.UserId);
        withAyse.Key.Should().Be(ayse.UserId.ToString());
        withAyse.Unread.Should().Be(1);
        (await mehmet.Client.GetFromJsonAsync<List<MessageBody>>($"/api/v1/families/{familyId}/chats/{ayse.UserId}/messages"))!
            .Should().ContainSingle(m => m.Body.StartsWith("Sürpriz"));

        var fatmaChats = await Chats(fatma!, familyId);
        fatmaChats.TotalUnread.Should().Be(0);
        fatmaChats.Chats.Should().OnlyContain(c => c.LastMessage == null);
        // Fatma can only address her own chats: there is no key for the chat between Ayşe and Mehmet.
        (await fatma!.Client.GetAsync($"/api/v1/families/{familyId}/chats/{fatma.UserId}/messages")).StatusCode.Should().Be(HttpStatusCode.NotFound);
        (await fatma.Client.GetAsync($"/api/v1/families/{familyId}/chats/{Guid.NewGuid()}/messages")).StatusCode.Should().Be(HttpStatusCode.NotFound);
    }

    [Fact]
    public async Task Strangers_cannot_read_or_write()
    {
        var (familyId, ayse, _, _) = await Family();
        await Send(ayse, familyId, "family", "Merhaba");
        var stranger = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Yabancı");
        (await stranger.GetAsync($"/api/v1/families/{familyId}/chats")).StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await stranger.GetAsync($"/api/v1/families/{familyId}/chats/family/messages")).StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await stranger.PostIdempotentAsync($"/api/v1/families/{familyId}/chats/family/messages", new { body = "x" })).StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }

    [Fact]
    public async Task A_message_can_point_at_a_task_of_the_family_only()
    {
        var (familyId, ayse, mehmet, _) = await Family();
        var task = (await (await ayse.Client.PostIdempotentAsync($"/api/v1/families/{familyId}/tasks", new { title = "Veli toplantısı formu", allDay = false }))
            .Content.ReadFromJsonAsync<TaskBody>())!;
        var sent = await Send(ayse, familyId, mehmet.UserId.ToString(), "Bunu sen imzalar mısın?", task.Id);
        sent.LinkTitle.Should().Be("Veli toplantısı formu");

        var (otherFamily, stranger, _, _) = await Family();
        (await stranger.Client.PostIdempotentAsync($"/api/v1/families/{otherFamily}/chats/family/messages", new { body = "x", taskId = task.Id }))
            .StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
        (await ayse.Client.PostIdempotentAsync($"/api/v1/families/{familyId}/chats/family/messages", new { body = "  " }))
            .StatusCode.Should().Be(HttpStatusCode.BadRequest);
    }

    [Fact]
    public async Task New_messages_are_pushed_to_the_other_adults_only()
    {
        var (familyId, ayse, mehmet, _) = await Family();
        var ayseToken = $"tok-{Guid.NewGuid():N}";
        var mehmetToken = $"tok-{Guid.NewGuid():N}";
        await ayse.Client.PutAsJsonAsync("/api/v1/me/devices", new { platform = "ios", token = ayseToken });
        await mehmet.Client.PutAsJsonAsync("/api/v1/me/devices", new { platform = "android", token = mehmetToken });

        await Send(ayse, familyId, mehmet.UserId.ToString(), "Okuldan sen alır mısın?");

        var push = api.Push.Sent.Where(p => p.Token == mehmetToken).Should().ContainSingle().Subject.Message;
        push.Title.Should().Be("Ayşe");
        push.Body.Should().Be("Okuldan sen alır mısın?");
        push.Data["kind"].Should().Be("Message");
        push.Data["chatKey"].Should().Be(ayse.UserId.ToString());
        api.Push.Sent.Should().NotContain(p => p.Token == ayseToken);
    }

    [Fact]
    public async Task Leaving_removes_direct_chats_but_keeps_family_messages_without_a_name()
    {
        var (familyId, ayse, mehmet, _) = await Family();
        await Send(mehmet, familyId, "family", "Ben çıkıyorum");
        await Send(mehmet, familyId, ayse.UserId.ToString(), "Özel not");

        (await mehmet.Client.PostIdempotentAsync($"/api/v1/families/{familyId}/leave", null)).IsSuccessStatusCode.Should().BeTrue();

        var family = await ayse.Client.GetFromJsonAsync<List<MessageBody>>($"/api/v1/families/{familyId}/chats/family/messages");
        family!.Should().ContainSingle().Which.SenderName.Should().BeNull();
        var chats = await Chats(ayse, familyId);
        chats.Chats.Should().ContainSingle(c => c.Key == "family");
        (await ayse.Client.GetAsync($"/api/v1/families/{familyId}/chats/{mehmet.UserId}/messages")).StatusCode.Should().Be(HttpStatusCode.NotFound);
    }
}
