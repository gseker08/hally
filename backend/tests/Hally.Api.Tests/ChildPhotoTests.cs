using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using FluentAssertions;

namespace Hally.Api.Tests;

public record ChildPhotoBody(Guid Id, string FirstName, string Color, string? PhotoUrl);
public record FamilyChildrenBody(Guid Id, List<ChildPhotoBody> Children);

[Collection(ApiCollection.Name)]
public class ChildPhotoTests(HallyApiFactory api)
{
    private static readonly byte[] Png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 1, 2, 3, 4];
    private static readonly byte[] Jpeg = [0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 0x4A, 0x46, 0x49, 0x46, 0, 1];

    private async Task<(HttpClient Client, Guid FamilyId, Guid ChildId)> FamilyWithChild()
    {
        var client = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Ayşe");
        var family = (await (await client.PostIdempotentAsync("/api/v1/families", new { name = "Aile" })).Content.ReadFromJsonAsync<FamilyBody>())!;
        var child = (await (await client.PostIdempotentAsync($"/api/v1/families/{family.Id}/children", new { firstName = "Ela" }))
            .Content.ReadFromJsonAsync<ChildPhotoBody>())!;
        return (client, family.Id, child.Id);
    }

    private static Task<HttpResponseMessage> Upload(HttpClient client, Guid familyId, Guid childId, byte[] bytes)
    {
        var form = new MultipartFormDataContent();
        var file = new ByteArrayContent(bytes);
        file.Headers.ContentType = new MediaTypeHeaderValue("image/png");
        form.Add(file, "file", "photo.png");
        return client.PutAsync($"/api/v1/families/{familyId}/children/{childId}/photo", form);
    }

    private string[] StoredFiles(Guid familyId)
    {
        var dir = Path.Combine(api.StorageRoot, familyId.ToString("N"));
        return Directory.Exists(dir) ? Directory.GetFiles(dir) : [];
    }

    [Fact]
    public async Task A_child_photo_is_stored_encrypted_and_shown_to_the_family_only()
    {
        var (client, familyId, childId) = await FamilyWithChild();
        var family = await client.GetFromJsonAsync<FamilyChildrenBody>($"/api/v1/families/{familyId}");
        family!.Children.Single().PhotoUrl.Should().BeNull();

        var res = await Upload(client, familyId, childId, Png);
        res.StatusCode.Should().Be(HttpStatusCode.OK);
        var child = (await res.Content.ReadFromJsonAsync<ChildPhotoBody>())!;
        child.PhotoUrl.Should().StartWith($"/api/v1/families/{familyId}/children/{childId}/photo?v=");

        family = await client.GetFromJsonAsync<FamilyChildrenBody>($"/api/v1/families/{familyId}");
        family!.Children.Single().PhotoUrl.Should().Be(child.PhotoUrl);

        var photo = await client.GetAsync(child.PhotoUrl);
        photo.StatusCode.Should().Be(HttpStatusCode.OK);
        photo.Content.Headers.ContentType!.MediaType.Should().Be("image/png");
        (await photo.Content.ReadAsByteArrayAsync()).Should().Equal(Png);

        var files = StoredFiles(familyId);
        files.Should().ContainSingle();
        (await File.ReadAllBytesAsync(files[0])).Should().NotContainInOrder(Png);

        var stranger = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Yabancı");
        (await stranger.GetAsync(child.PhotoUrl)).StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await Upload(stranger, familyId, childId, Png)).StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }

    [Fact]
    public async Task Replacing_and_removing_a_photo_deletes_the_old_file()
    {
        var (client, familyId, childId) = await FamilyWithChild();
        var first = (await (await Upload(client, familyId, childId, Png)).Content.ReadFromJsonAsync<ChildPhotoBody>())!;
        api.Clock.Advance(TimeSpan.FromSeconds(5));
        ChildPhotoBody second;
        try
        {
            second = (await (await Upload(client, familyId, childId, Jpeg)).Content.ReadFromJsonAsync<ChildPhotoBody>())!;
        }
        finally
        {
            api.Clock.Advance(TimeSpan.FromSeconds(-5));
        }

        second.PhotoUrl.Should().NotBe(first.PhotoUrl);
        StoredFiles(familyId).Should().ContainSingle();
        var photo = await client.GetAsync(second.PhotoUrl);
        photo.Content.Headers.ContentType!.MediaType.Should().Be("image/jpeg");

        var removed = await client.DeleteAsync($"/api/v1/families/{familyId}/children/{childId}/photo");
        removed.StatusCode.Should().Be(HttpStatusCode.OK);
        (await removed.Content.ReadFromJsonAsync<ChildPhotoBody>())!.PhotoUrl.Should().BeNull();
        StoredFiles(familyId).Should().BeEmpty();
        (await client.GetAsync($"/api/v1/families/{familyId}/children/{childId}/photo")).StatusCode.Should().Be(HttpStatusCode.NotFound);
    }

    [Fact]
    public async Task Deleting_the_child_deletes_its_photo()
    {
        var (client, familyId, childId) = await FamilyWithChild();
        await Upload(client, familyId, childId, Png);
        StoredFiles(familyId).Should().ContainSingle();

        (await client.DeleteAsync($"/api/v1/families/{familyId}/children/{childId}")).StatusCode.Should().Be(HttpStatusCode.NoContent);
        StoredFiles(familyId).Should().BeEmpty();
    }

    [Fact]
    public async Task Something_that_is_not_a_photo_is_refused()
    {
        var (client, familyId, childId) = await FamilyWithChild();
        var res = await Upload(client, familyId, childId, "not a photo"u8.ToArray());
        res.StatusCode.Should().BeOneOf(HttpStatusCode.BadRequest, HttpStatusCode.UnprocessableEntity);
        (await res.Content.ReadAsStringAsync()).Should().Contain("child.photo_invalid");
        StoredFiles(familyId).Should().BeEmpty();
    }
}
