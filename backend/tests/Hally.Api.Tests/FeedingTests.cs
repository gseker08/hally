using System.Net;
using System.Net.Http.Json;
using FluentAssertions;
using Hally.Domain.Feeding;

namespace Hally.Api.Tests;

public record FeedingEntryBody(Guid Id, Guid ChildId, string Kind, DateTimeOffset At, string? Side, int? Minutes, int? AmountMl, string? Food,
    string? Note, string? ByName);
public record ChildFeedingStatusBody(Guid ChildId, FeedingEntryBody? Last, string? NextSide, int FeedsToday, int BottleMlToday);
public record FeedingDayBody(DateOnly Date, int Feeds, int BreastFeeds, int BreastMinutes, int Bottles, int BottleMl, int Solids);
public record ChildFeedingHistoryBody(Guid ChildId, List<FeedingDayBody> Days, List<FeedingEntryBody> Entries);

[Collection(ApiCollection.Name)]
public class FeedingTests(HallyApiFactory api)
{
    private async Task<(HttpClient Owner, HttpClient Partner, Guid FamilyId, Guid ChildId)> FamilyWithChild()
    {
        var owner = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Ayşe");
        var family = (await (await owner.PostIdempotentAsync("/api/v1/families", new { name = "Yılmaz" })).Content.ReadFromJsonAsync<FamilyBody>())!;
        var invite = (await (await owner.PostIdempotentAsync($"/api/v1/families/{family.Id}/invitations", null)).Content.ReadFromJsonAsync<InvitationBody>())!;
        var partner = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Mehmet");
        await partner.PostIdempotentAsync($"/api/v1/invitations/{invite.Token}/accept", null);
        var child = (await (await owner.PostIdempotentAsync($"/api/v1/families/{family.Id}/children", new { firstName = "Can" })).Content.ReadFromJsonAsync<ChildBody>())!;
        return (owner, partner, family.Id, child.Id);
    }

    [Fact]
    public void Next_side_alternates_after_one_side()
    {
        FeedingEntry.NextSide(BreastSide.Left).Should().Be(BreastSide.Right);
        FeedingEntry.NextSide(BreastSide.Right).Should().Be(BreastSide.Left);
        FeedingEntry.NextSide(BreastSide.Both).Should().BeNull();
        FeedingEntry.NextSide(null).Should().BeNull();
    }

    [Fact]
    public async Task Feeds_by_both_parents_show_last_feed_next_side_and_daily_totals()
    {
        var (owner, partner, familyId, childId) = await FamilyWithChild();
        var url = $"/api/v1/families/{familyId}/children/{childId}/feeding";
        var now = api.Clock.GetUtcNow();

        var breast = await owner.PostAsJsonAsync(url, new { kind = "Breast", side = "Left", minutes = 15, at = now.AddMinutes(-120) });
        breast.StatusCode.Should().Be(HttpStatusCode.Created);
        (await breast.Content.ReadFromJsonAsync<ChildFeedingStatusBody>())!.NextSide.Should().Be("Right");

        var bottle = (await (await partner.PostAsJsonAsync(url, new { kind = "Bottle", amountMl = 120, at = now.AddMinutes(-30) }))
            .Content.ReadFromJsonAsync<ChildFeedingStatusBody>())!;
        bottle.Last!.Kind.Should().Be("Bottle");
        bottle.Last.ByName.Should().Be("Mehmet");
        bottle.NextSide.Should().Be("Right", "a bottle does not change the breast side");

        var status = (await owner.GetFromJsonAsync<List<ChildFeedingStatusBody>>($"/api/v1/families/{familyId}/feeding"))!.Single();
        status.BottleMlToday.Should().Be(120);

        var history = (await owner.GetFromJsonAsync<ChildFeedingHistoryBody>($"{url}?days=3"))!;
        history.Days.Should().HaveCount(3);
        history.Days.Sum(d => d.BreastMinutes).Should().Be(15);
        history.Days.Sum(d => d.BottleMl).Should().Be(120);
        history.Entries.Select(e => e.Kind).Should().Equal("Bottle", "Breast");

        var deleted = (await (await owner.DeleteAsync($"{url}/{history.Entries[0].Id}")).Content.ReadFromJsonAsync<ChildFeedingStatusBody>())!;
        deleted.Last!.Kind.Should().Be("Breast");
    }

    [Fact]
    public async Task Feeds_need_the_field_for_their_kind_and_cannot_be_in_the_future()
    {
        var (owner, _, familyId, childId) = await FamilyWithChild();
        var url = $"/api/v1/families/{familyId}/children/{childId}/feeding";

        (await owner.PostAsJsonAsync(url, new { kind = "Breast" })).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
        (await owner.PostAsJsonAsync(url, new { kind = "Bottle" })).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
        (await owner.PostAsJsonAsync(url, new { kind = "Solid", food = " " })).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
        (await owner.PostAsJsonAsync(url, new { kind = "Bottle", amountMl = 100, at = api.Clock.GetUtcNow().AddHours(1) }))
            .StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
        (await owner.PostAsJsonAsync(url, new { kind = "Bottle", amountMl = 900 })).StatusCode.Should().BeOneOf(HttpStatusCode.UnprocessableEntity, HttpStatusCode.BadRequest);

        var solid = (await (await owner.PostAsJsonAsync(url, new { kind = "Solid", food = " Havuç püresi " })).Content.ReadFromJsonAsync<ChildFeedingStatusBody>())!;
        solid.Last!.Food.Should().Be("Havuç püresi");
        solid.Last.AmountMl.Should().BeNull();
    }
}
