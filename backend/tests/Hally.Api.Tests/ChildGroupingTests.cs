using System.Net;
using System.Net.Http.Json;
using FluentAssertions;

namespace Hally.Api.Tests;

public record ChildBody(Guid Id, string FirstName, int? BirthYear, string Color);
public record FamilyWithChildrenBody(Guid Id, List<ChildBody> Children);
public record TaggedTaskBody(Guid Id, string Title, Guid? ChildId, List<Guid> ChildIds);
public record TaggedEventBody(Guid Id, string Title, Guid? ChildId, List<Guid> ChildIds);
public record SavedTaggedEventBody(TaggedEventBody Event);

[Collection(ApiCollection.Name)]
public class ChildGroupingTests(HallyApiFactory api)
{
    private async Task<(HttpClient Client, Guid FamilyId)> Family()
    {
        var client = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Ayşe");
        var family = (await (await client.PostIdempotentAsync("/api/v1/families", new { name = "Aile", timeZoneId = "Europe/Istanbul" })).Content.ReadFromJsonAsync<FamilyBody>())!;
        return (client, family.Id);
    }

    private static async Task<ChildBody> AddChild(HttpClient c, Guid familyId, string name, string? color = null) =>
        (await (await c.PostIdempotentAsync($"/api/v1/families/{familyId}/children", new { firstName = name, color })).Content.ReadFromJsonAsync<ChildBody>())!;

    [Fact]
    public async Task Siblings_get_different_colours_and_can_be_recoloured()
    {
        var (c, familyId) = await Family();
        var ela = await AddChild(c, familyId, "Ela");
        var can = await AddChild(c, familyId, "Can");
        var mert = await AddChild(c, familyId, "Mert", color: "sky");
        ela.Color.Should().Be("sky");
        can.Color.Should().Be("mint");
        mert.Color.Should().Be("sky", "an explicit colour may repeat");

        var updated = await (await c.PutAsJsonAsync($"/api/v1/families/{familyId}/children/{mert.Id}", new { firstName = "Mert Ali", birthYear = 2019, color = "teal" }))
            .Content.ReadFromJsonAsync<ChildBody>();
        updated.Should().Be(new ChildBody(mert.Id, "Mert Ali", 2019, "teal"));

        (await c.PutAsJsonAsync($"/api/v1/families/{familyId}/children/{mert.Id}", new { firstName = "Mert", color = "red" }))
            .StatusCode.Should().Be(HttpStatusCode.BadRequest, "red is the brand colour, not a child colour");
        (await c.PostIdempotentAsync($"/api/v1/families/{familyId}/children", new { firstName = "X", color = "orange" }))
            .StatusCode.Should().Be(HttpStatusCode.BadRequest);

        var family = await c.GetFromJsonAsync<FamilyWithChildrenBody>($"/api/v1/families/{familyId}");
        family!.Children.Select(k => k.Color).Should().Equal("sky", "mint", "teal");
    }

    [Fact]
    public async Task Tasks_and_events_can_be_tagged_with_several_children_and_filtered()
    {
        var (c, familyId) = await Family();
        var ela = await AddChild(c, familyId, "Ela");
        var can = await AddChild(c, familyId, "Can");

        var both = (await (await c.PostIdempotentAsync($"/api/v1/families/{familyId}/tasks",
            new { title = "Veli toplantısı formu", allDay = false, childIds = new[] { ela.Id, can.Id } })).Content.ReadFromJsonAsync<TaggedTaskBody>())!;
        both.ChildIds.Should().Equal(ela.Id, can.Id);
        both.ChildId.Should().Be(ela.Id);
        var legacy = (await (await c.PostIdempotentAsync($"/api/v1/families/{familyId}/tasks",
            new { title = "Ödev", allDay = false, childId = can.Id })).Content.ReadFromJsonAsync<TaggedTaskBody>())!;
        legacy.ChildIds.Should().Equal(can.Id);
        await c.PostIdempotentAsync($"/api/v1/families/{familyId}/tasks", new { title = "Ekmek al", allDay = false });

        var elaTasks = await c.GetFromJsonAsync<List<TaggedTaskBody>>($"/api/v1/families/{familyId}/tasks?child={ela.Id}");
        elaTasks!.Select(t => t.Title).Should().Equal("Veli toplantısı formu");
        var canTasks = await c.GetFromJsonAsync<List<TaggedTaskBody>>($"/api/v1/families/{familyId}/tasks?child={can.Id}");
        canTasks!.Should().HaveCount(2);

        var start = new DateTimeOffset(2026, 12, 3, 12, 0, 0, TimeSpan.Zero);
        var evt = (await (await c.PostIdempotentAsync($"/api/v1/families/{familyId}/events",
            new { title = "Yüzme", startsAt = start, allDay = false, childIds = new[] { can.Id }, repeat = "Weekly" })).Content.ReadFromJsonAsync<SavedTaggedEventBody>())!;
        evt.Event.ChildIds.Should().Equal(can.Id);
        var range = $"from={Uri.EscapeDataString(start.AddDays(-1).ToString("O"))}&to={Uri.EscapeDataString(start.AddDays(20).ToString("O"))}";
        (await c.GetFromJsonAsync<List<TaggedEventBody>>($"/api/v1/families/{familyId}/events?{range}&child={can.Id}"))!.Should().HaveCount(3);
        (await c.GetFromJsonAsync<List<TaggedEventBody>>($"/api/v1/families/{familyId}/events?{range}&child={ela.Id}"))!.Should().BeEmpty();
    }

    [Fact]
    public async Task A_child_of_another_family_cannot_be_tagged()
    {
        var (a, familyA) = await Family();
        var (b, familyB) = await Family();
        var own = await AddChild(a, familyA, "Ela");
        var foreign = await AddChild(b, familyB, "Zeynep");

        (await a.PostIdempotentAsync($"/api/v1/families/{familyA}/tasks", new { title = "X", allDay = false, childIds = new[] { own.Id, foreign.Id } }))
            .StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
        (await a.PutAsJsonAsync($"/api/v1/families/{familyB}/children/{foreign.Id}", new { firstName = "Hack", color = "sky" }))
            .StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await a.DeleteAsync($"/api/v1/families/{familyA}/children/{foreign.Id}")).StatusCode.Should().Be(HttpStatusCode.NotFound);
    }

    [Fact]
    public async Task Deleting_a_child_untags_it_but_keeps_the_items()
    {
        var (c, familyId) = await Family();
        var ela = await AddChild(c, familyId, "Ela");
        var can = await AddChild(c, familyId, "Can");
        var task = (await (await c.PostIdempotentAsync($"/api/v1/families/{familyId}/tasks",
            new { title = "Gezi izni", allDay = false, childIds = new[] { ela.Id, can.Id } })).Content.ReadFromJsonAsync<TaggedTaskBody>())!;
        var start = new DateTimeOffset(2026, 12, 5, 9, 0, 0, TimeSpan.Zero);
        var evt = (await (await c.PostIdempotentAsync($"/api/v1/families/{familyId}/events",
            new { title = "Gezi", startsAt = start, allDay = false, childIds = new[] { ela.Id } })).Content.ReadFromJsonAsync<SavedTaggedEventBody>())!;

        (await c.DeleteAsync($"/api/v1/families/{familyId}/children/{ela.Id}")).StatusCode.Should().Be(HttpStatusCode.NoContent);

        (await c.GetFromJsonAsync<TaggedTaskBody>($"/api/v1/families/{familyId}/tasks/{task.Id}"))!.ChildIds.Should().Equal(can.Id);
        var events = await c.GetFromJsonAsync<List<TaggedEventBody>>(
            $"/api/v1/families/{familyId}/events?from={Uri.EscapeDataString(start.AddHours(-1).ToString("O"))}&to={Uri.EscapeDataString(start.AddHours(2).ToString("O"))}");
        events!.Single(e => e.Id == evt.Event.Id).ChildIds.Should().BeEmpty();
        (await c.GetFromJsonAsync<FamilyWithChildrenBody>($"/api/v1/families/{familyId}"))!.Children.Should().ContainSingle(k => k.Id == can.Id);
    }
}
