using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using FluentAssertions;

namespace Hally.Api.Tests;

public record PhotoMessageBody(Guid Id, Guid SenderUserId, string Body, bool HasPhoto);

[Collection(ApiCollection.Name)]
public class MessagePhotoTests(HallyApiFactory api)
{
    // Smallest valid PNG header plus some bytes; the server only checks the signature.
    private static readonly byte[] Png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 1, 2, 3, 4];

    private record Adult(HttpClient Client, Guid UserId);

    private async Task<(Guid FamilyId, Adult Ayse, Adult Mehmet)> Family()
    {
        var owner = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Ayşe Yılmaz");
        var family = (await (await owner.PostIdempotentAsync("/api/v1/families", new { name = "Aile" })).Content.ReadFromJsonAsync<FamilyBody>())!;
        var invite = (await (await owner.PostIdempotentAsync($"/api/v1/families/{family.Id}/invitations", null)).Content.ReadFromJsonAsync<InvitationBody>())!;
        var client = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Mehmet");
        (await client.PostIdempotentAsync($"/api/v1/invitations/{invite.Token}/accept", null)).StatusCode.Should().Be(HttpStatusCode.OK);
        return (family.Id,
            new Adult(owner, (await owner.GetFromJsonAsync<MeBody>("/api/v1/me"))!.Id),
            new Adult(client, (await client.GetFromJsonAsync<MeBody>("/api/v1/me"))!.Id));
    }

    private static Task<HttpResponseMessage> SendPhoto(Adult from, Guid familyId, string key, byte[] bytes, string? caption = null,
        string declaredType = "image/png")
    {
        var form = new MultipartFormDataContent();
        var file = new ByteArrayContent(bytes);
        file.Headers.ContentType = new MediaTypeHeaderValue(declaredType);
        form.Add(file, "file", "photo.png");
        if (caption is not null)
        {
            form.Add(new StringContent(caption), "caption");
        }

        var request = new HttpRequestMessage(HttpMethod.Post, $"/api/v1/families/{familyId}/chats/{key}/photos") { Content = form };
        request.Headers.Add("Idempotency-Key", Guid.NewGuid().ToString());
        return from.Client.SendAsync(request);
    }

    [Fact]
    public async Task A_photo_is_stored_encrypted_and_readable_by_the_chat_only()
    {
        var (familyId, ayse, mehmet) = await Family();
        var res = await SendPhoto(ayse, familyId, "family", Png, "Karne!");
        res.StatusCode.Should().Be(HttpStatusCode.Created);
        var sent = (await res.Content.ReadFromJsonAsync<PhotoMessageBody>())!;
        sent.HasPhoto.Should().BeTrue();
        sent.Body.Should().Be("Karne!");

        var list = await mehmet.Client.GetFromJsonAsync<List<PhotoMessageBody>>($"/api/v1/families/{familyId}/chats/family/messages");
        list!.Should().ContainSingle().Which.HasPhoto.Should().BeTrue();

        var photo = await mehmet.Client.GetAsync($"/api/v1/families/{familyId}/chats/family/messages/{sent.Id}/photo");
        photo.StatusCode.Should().Be(HttpStatusCode.OK);
        photo.Content.Headers.ContentType!.MediaType.Should().Be("image/png");
        (await photo.Content.ReadAsByteArrayAsync()).Should().Equal(Png);

        // On disk it is encrypted, never the original bytes.
        var files = Directory.GetFiles(Path.Combine(api.StorageRoot, familyId.ToString("N")));
        files.Should().ContainSingle();
        (await File.ReadAllBytesAsync(files[0])).Should().NotContainInOrder(Png);

        // A stranger gets nothing.
        var stranger = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Yabancı");
        (await stranger.GetAsync($"/api/v1/families/{familyId}/chats/family/messages/{sent.Id}/photo")).StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }

    [Fact]
    public async Task A_photo_without_caption_is_fine_and_push_says_photo()
    {
        var (familyId, ayse, mehmet) = await Family();
        var token = $"tok-{Guid.NewGuid():N}";
        await mehmet.Client.PutAsJsonAsync("/api/v1/me/devices", new { platform = "android", token });

        var res = await SendPhoto(ayse, familyId, mehmet.UserId.ToString(), Png);
        res.StatusCode.Should().Be(HttpStatusCode.Created);
        (await res.Content.ReadFromJsonAsync<PhotoMessageBody>())!.Body.Should().BeEmpty();

        var push = api.Push.Sent.Where(p => p.Token == token).Should().ContainSingle().Subject.Message;
        push.Body.Should().Be("📷 Fotoğraf");
        push.Data["chatKey"].Should().Be(ayse.UserId.ToString());
    }

    [Fact]
    public async Task Something_that_is_not_an_image_is_refused_whatever_its_declared_type()
    {
        var (familyId, ayse, _) = await Family();
        var html = "<html><script>alert(1)</script></html>"u8.ToArray();
        (await SendPhoto(ayse, familyId, "family", html)).StatusCode.Should().BeOneOf(HttpStatusCode.BadRequest, HttpStatusCode.UnprocessableEntity);
        (await SendPhoto(ayse, familyId, "family", [])).StatusCode.Should().BeOneOf(HttpStatusCode.BadRequest, HttpStatusCode.UnprocessableEntity);
        Directory.Exists(Path.Combine(api.StorageRoot, familyId.ToString("N"))).Should().BeFalse("nothing is stored for a refused upload");
    }

    [Fact]
    public async Task A_direct_chat_photo_is_private_and_deleted_when_the_other_adult_leaves()
    {
        var (familyId, ayse, mehmet) = await Family();
        var res = await SendPhoto(ayse, familyId, mehmet.UserId.ToString(), Png);
        var sent = (await res.Content.ReadFromJsonAsync<PhotoMessageBody>())!;
        // Ayşe reads it through her key for the chat (Mehmet's id); the family chat key does not reach it.
        (await ayse.Client.GetAsync($"/api/v1/families/{familyId}/chats/{mehmet.UserId}/messages/{sent.Id}/photo")).StatusCode.Should().Be(HttpStatusCode.OK);
        (await ayse.Client.GetAsync($"/api/v1/families/{familyId}/chats/family/messages/{sent.Id}/photo")).StatusCode.Should().Be(HttpStatusCode.NotFound);

        var folder = Path.Combine(api.StorageRoot, familyId.ToString("N"));
        Directory.GetFiles(folder).Should().ContainSingle();
        (await mehmet.Client.PostIdempotentAsync($"/api/v1/families/{familyId}/leave", null)).IsSuccessStatusCode.Should().BeTrue();
        Directory.GetFiles(folder).Should().BeEmpty();
    }
}
