using System.Net;
using System.Net.Http.Json;
using FluentAssertions;
using Hally.Api.Features.Shopping;

namespace Hally.Api.Tests;

public record ShoppingItemBody(Guid Id, string Text, string? Quantity, Guid? AddedByUserId, string? AddedByName, DateTimeOffset CreatedAt,
    DateTimeOffset? CheckedAt, Guid? CheckedByUserId, string? CheckedByName);
public record ShoppingListBody(List<ShoppingItemBody> Open, List<ShoppingItemBody> Checked);
public record AddShoppingBody(List<ShoppingItemBody> Added, List<ShoppingItemBody> AlreadyOnList, ShoppingListBody List);

[Collection(ApiCollection.Name)]
public class ShoppingTests(HallyApiFactory api)
{
    private async Task<(HttpClient Owner, HttpClient Partner, Guid FamilyId)> TwoAdults()
    {
        var owner = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Ayşe");
        var family = (await (await owner.PostIdempotentAsync("/api/v1/families", new { name = "Yılmaz" })).Content.ReadFromJsonAsync<FamilyBody>())!;
        var invite = (await (await owner.PostIdempotentAsync($"/api/v1/families/{family.Id}/invitations", null)).Content.ReadFromJsonAsync<InvitationBody>())!;
        var partner = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Mehmet", "en");
        await partner.PostIdempotentAsync($"/api/v1/invitations/{invite.Token}/accept", null);
        return (owner, partner, family.Id);
    }

    [Fact]
    public void Lines_split_on_commas_and_new_lines_but_not_decimal_commas()
    {
        ShoppingController.SplitLines("süt, ekmek\n- 1,5 kg domates\n\n• yumurta ,")
            .Should().Equal("süt", "ekmek", "1,5 kg domates", "yumurta");
    }

    [Fact]
    public async Task Both_adults_share_one_list_without_duplicates()
    {
        var (owner, partner, familyId) = await TwoAdults();
        var url = $"/api/v1/families/{familyId}/shopping";

        var first = await owner.PostAsJsonAsync($"{url}/items", new { text = "Süt, ekmek" });
        first.StatusCode.Should().Be(HttpStatusCode.Created);
        (await first.Content.ReadFromJsonAsync<AddShoppingBody>())!.Added.Select(i => i.Text).Should().Equal("Süt", "ekmek");

        var second = (await (await partner.PostAsJsonAsync($"{url}/items", new { text = "SÜT", quantity = "2 L" })).Content.ReadFromJsonAsync<AddShoppingBody>())!;
        second.Added.Should().BeEmpty();
        second.AlreadyOnList.Should().ContainSingle().Which.AddedByName.Should().Be("Ayşe");

        var list = (await partner.GetFromJsonAsync<ShoppingListBody>(url))!;
        list.Open.Select(i => i.Text).Should().Equal("Süt", "ekmek");

        var milk = list.Open[0];
        var afterCheck = (await (await partner.PatchAsJsonAsync($"{url}/items/{milk.Id}", new { @checked = true })).Content.ReadFromJsonAsync<ShoppingListBody>())!;
        afterCheck.Open.Should().ContainSingle();
        afterCheck.Checked.Should().ContainSingle().Which.CheckedByName.Should().Be("Mehmet");

        // Once bought, adding it again is a new item.
        (await (await owner.PostAsJsonAsync($"{url}/items", new { text = "süt" })).Content.ReadFromJsonAsync<AddShoppingBody>())!.Added.Should().ContainSingle();

        var cleared = (await (await owner.PostAsync($"{url}/clear-checked", null)).Content.ReadFromJsonAsync<ShoppingListBody>())!;
        cleared.Checked.Should().BeEmpty();
        cleared.Open.Should().HaveCount(2);

        var edited = (await (await owner.PatchAsJsonAsync($"{url}/items/{cleared.Open[0].Id}", new { quantity = "1 paket" })).Content.ReadFromJsonAsync<ShoppingListBody>())!;
        edited.Open[0].Quantity.Should().Be("1 paket");
        edited.Open[0].Text.Should().Be("ekmek");

        (await owner.DeleteAsync($"{url}/items/{cleared.Open[0].Id}")).StatusCode.Should().Be(HttpStatusCode.OK);
        (await owner.GetFromJsonAsync<ShoppingListBody>(url))!.Open.Should().ContainSingle();
    }

    [Fact]
    public async Task Heading_out_pushes_the_others_once()
    {
        var (owner, partner, familyId) = await TwoAdults();
        var token = $"tok-{Guid.NewGuid():N}";
        await partner.PutAsJsonAsync("/api/v1/me/devices", new { platform = "android", token });
        await owner.PostAsJsonAsync($"/api/v1/families/{familyId}/shopping/items", new { text = "elma, armut, peynir" });

        (await owner.PostAsync($"/api/v1/families/{familyId}/shopping/heading-out", null)).StatusCode.Should().Be(HttpStatusCode.Accepted);
        (await owner.PostAsync($"/api/v1/families/{familyId}/shopping/heading-out", null)).StatusCode.Should().Be(HttpStatusCode.Accepted);

        var pushes = api.Push.Sent.Where(p => p.Token == token).ToList();
        pushes.Should().ContainSingle();
        pushes[0].Message.Title.Should().Be("Ayşe is going shopping");
        pushes[0].Message.Body.Should().StartWith("3 items");
    }

    [Fact]
    public async Task Other_families_cannot_see_the_list()
    {
        var (owner, _, familyId) = await TwoAdults();
        await owner.PostAsJsonAsync($"/api/v1/families/{familyId}/shopping/items", new { text = "gizli" });
        var stranger = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Yabancı");
        (await stranger.GetAsync($"/api/v1/families/{familyId}/shopping")).StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await owner.PostAsJsonAsync($"/api/v1/families/{familyId}/shopping/items", new { text = " , " })).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
    }
}
