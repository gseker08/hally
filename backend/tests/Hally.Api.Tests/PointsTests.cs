using System.Net;
using System.Net.Http.Json;
using FluentAssertions;

namespace Hally.Api.Tests;

public record ChoreBody(Guid Id, string Title, int Points, Guid? ChildId);
public record RewardBody(Guid Id, string Title, int Cost);
public record ChildPointsBody(Guid ChildId, int Balance, int WeekPoints, Dictionary<Guid, Guid> DoneToday);
public record PointsBoardBody(List<ChoreBody> Chores, List<RewardBody> Rewards, List<ChildPointsBody> Children);
public record PointEntryBody(Guid Id, string Kind, string Title, int Points, DateOnly Day, DateTimeOffset At, string? ByName);

[Collection(ApiCollection.Name)]
public class PointsTests(HallyApiFactory api)
{
    private async Task<(HttpClient Owner, HttpClient Partner, Guid FamilyId, Guid Ela, Guid Can)> FamilyWithChildren()
    {
        var owner = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Ayşe");
        var family = (await (await owner.PostIdempotentAsync("/api/v1/families", new { name = "Yılmaz", timeZoneId = TestZones.Daytime(api.Clock) })).Content.ReadFromJsonAsync<FamilyBody>())!;
        var invite = (await (await owner.PostIdempotentAsync($"/api/v1/families/{family.Id}/invitations", null)).Content.ReadFromJsonAsync<InvitationBody>())!;
        var partner = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Mehmet");
        await partner.PostIdempotentAsync($"/api/v1/invitations/{invite.Token}/accept", null);
        var ela = (await (await owner.PostIdempotentAsync($"/api/v1/families/{family.Id}/children", new { firstName = "Ela" })).Content.ReadFromJsonAsync<ChildBody>())!;
        var can = (await (await owner.PostIdempotentAsync($"/api/v1/families/{family.Id}/children", new { firstName = "Can" })).Content.ReadFromJsonAsync<ChildBody>())!;
        return (owner, partner, family.Id, ela.Id, can.Id);
    }

    [Fact]
    public async Task Chores_add_stars_once_a_day_and_rewards_spend_them()
    {
        var (owner, partner, familyId, ela, _) = await FamilyWithChildren();
        var f = $"/api/v1/families/{familyId}";
        var room = (await (await owner.PostAsJsonAsync($"{f}/chores", new { title = " Odanı topla ", points = 5 })).Content.ReadFromJsonAsync<ChoreBody>())!;
        room.Title.Should().Be("Odanı topla");
        var table = (await (await owner.PostAsJsonAsync($"{f}/chores", new { title = "Sofrayı kur", points = 3 })).Content.ReadFromJsonAsync<ChoreBody>())!;
        var park = (await (await owner.PostAsJsonAsync($"{f}/rewards", new { title = "Parka gitmek", cost = 7 })).Content.ReadFromJsonAsync<RewardBody>())!;

        await owner.PostAsync($"{f}/children/{ela}/chores/{room.Id}/done", null);
        var board = (await (await partner.PostAsync($"{f}/children/{ela}/chores/{room.Id}/done", null)).Content.ReadFromJsonAsync<PointsBoardBody>())!;
        var elaPoints = board.Children.Single(c => c.ChildId == ela);
        elaPoints.Balance.Should().Be(5, "the same chore counts once a day");
        elaPoints.DoneToday.Should().ContainKey(room.Id);

        (await owner.PostAsync($"{f}/children/{ela}/rewards/{park.Id}/redeem", null)).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
        await owner.PostAsync($"{f}/children/{ela}/chores/{table.Id}/done", null);
        board = (await (await owner.PostAsync($"{f}/children/{ela}/rewards/{park.Id}/redeem", null)).Content.ReadFromJsonAsync<PointsBoardBody>())!;
        board.Children.Single(c => c.ChildId == ela).Balance.Should().Be(1);
        board.Children.Single(c => c.ChildId == ela).WeekPoints.Should().Be(8);

        var history = (await owner.GetFromJsonAsync<List<PointEntryBody>>($"{f}/children/{ela}/points"))!;
        history.Select(h => h.Points).Should().Equal(-7, 3, 5);
        history[0].Title.Should().Be("Parka gitmek");

        // Undo the reward; deleting a chore keeps the stars already earned.
        await owner.DeleteAsync($"{f}/children/{ela}/points/{history[0].Id}");
        (await owner.DeleteAsync($"{f}/chores/{room.Id}")).StatusCode.Should().Be(HttpStatusCode.NoContent);
        board = (await owner.GetFromJsonAsync<PointsBoardBody>($"{f}/points"))!;
        board.Children.Single(c => c.ChildId == ela).Balance.Should().Be(8);
        board.Chores.Should().ContainSingle().Which.Title.Should().Be("Sofrayı kur");
    }

    [Fact]
    public async Task A_chore_for_one_child_cannot_be_ticked_for_another()
    {
        var (owner, _, familyId, ela, can) = await FamilyWithChildren();
        var f = $"/api/v1/families/{familyId}";
        var feed = (await (await owner.PostAsJsonAsync($"{f}/chores", new { title = "Kediyi besle", points = 2, childId = can })).Content.ReadFromJsonAsync<ChoreBody>())!;
        (await owner.PostAsync($"{f}/children/{ela}/chores/{feed.Id}/done", null)).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
        (await owner.PostAsync($"{f}/children/{can}/chores/{feed.Id}/done", null)).StatusCode.Should().Be(HttpStatusCode.OK);
        (await owner.PostAsJsonAsync($"{f}/chores", new { title = "x", points = 99 })).StatusCode.Should().Be(HttpStatusCode.BadRequest);
    }
}
