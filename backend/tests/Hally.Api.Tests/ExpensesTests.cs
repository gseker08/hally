using System.Net;
using System.Net.Http.Json;
using FluentAssertions;
using Hally.Domain.Expenses;

namespace Hally.Api.Tests;

public record ExpenseBody(Guid Id, string Title, decimal Amount, string Category, DateOnly Date, Guid PaidByUserId, string? PaidByName, Guid? ChildId,
    string? Note, decimal MyShare);
public record SettlementBody(Guid Id, Guid FromUserId, string? FromName, Guid ToUserId, string? ToName, decimal Amount, DateOnly Date);
public record CategoryTotalBody(string Category, decimal Amount);
public record ExpenseBalanceBody(Guid UserId, string Name, decimal Net);
public record SettleSuggestionBody(Guid FromUserId, string FromName, Guid ToUserId, string ToName, decimal Amount);
public record ExpenseMonthBody(string Month, string Currency, decimal Total, List<CategoryTotalBody> ByCategory, List<ExpenseBody> Expenses,
    List<SettlementBody> Settlements, List<ExpenseBalanceBody> Balances, SettleSuggestionBody? Suggestion);

[Collection(ApiCollection.Name)]
public class ExpensesTests(HallyApiFactory api)
{
    [Fact]
    public void Odd_amounts_leave_the_extra_kurus_with_the_payer()
    {
        var a = Guid.NewGuid();
        var b = Guid.NewGuid();
        var c = Guid.NewGuid();
        var e = new Expense(Guid.NewGuid(), "Kitap", 100m, ExpenseCategory.School, new DateOnly(2026, 11, 23), a, [a, b, c], null, null, a, DateTimeOffset.UtcNow);
        e.ShareOf(b).Should().Be(33.33m);
        e.ShareOf(a).Should().Be(33.34m);
        var net = Settlement.Balances([e], []);
        net[a].Should().Be(66.66m);
        (net[b] + net[c]).Should().Be(-66.66m);
    }

    [Fact]
    public async Task Two_parents_split_costs_and_settle_up()
    {
        var owner = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Ayşe");
        var family = (await (await owner.PostIdempotentAsync("/api/v1/families", new { name = "Yılmaz" })).Content.ReadFromJsonAsync<FamilyBody>())!;
        var invite = (await (await owner.PostIdempotentAsync($"/api/v1/families/{family.Id}/invitations", null)).Content.ReadFromJsonAsync<InvitationBody>())!;
        var partner = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Mehmet");
        await partner.PostIdempotentAsync($"/api/v1/invitations/{invite.Token}/accept", null);
        var url = $"/api/v1/families/{family.Id}/expenses";

        var added = await owner.PostAsJsonAsync(url, new { title = "Okul servisi", amount = 1200m, category = "School" });
        added.StatusCode.Should().Be(HttpStatusCode.Created);
        await partner.PostAsJsonAsync(url, new { title = "Doktor", amount = 500.50m, category = "Health" });

        var month = (await owner.GetFromJsonAsync<ExpenseMonthBody>(url))!;
        month.Currency.Should().Be("TRY");
        month.Total.Should().Be(1700.50m);
        month.ByCategory.Select(c => c.Category).Should().Equal("School", "Health");
        month.Expenses.Should().HaveCount(2);
        month.Expenses.Single(e => e.Title == "Okul servisi").MyShare.Should().Be(600m);
        month.Suggestion!.FromName.Should().Be("Mehmet");
        month.Suggestion.ToName.Should().Be("Ayşe");
        month.Suggestion.Amount.Should().Be(349.75m);

        var settled = await partner.PostAsJsonAsync($"{url}/settlements", new { toUserId = month.Suggestion.ToUserId, amount = 349.75m });
        settled.StatusCode.Should().Be(HttpStatusCode.Created);
        month = (await settled.Content.ReadFromJsonAsync<ExpenseMonthBody>())!;
        month.Suggestion.Should().BeNull();
        month.Balances.Should().OnlyContain(b => b.Net == 0);
        month.Settlements.Should().ContainSingle().Which.FromName.Should().Be("Mehmet");

        (await owner.PostAsJsonAsync(url, new { title = "x", amount = 10.555m })).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
        (await owner.PostAsJsonAsync(url, new { title = "x", amount = 10m, paidByUserId = Guid.NewGuid() })).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
        (await owner.GetAsync($"{url}?month=2026-13")).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);

        month = (await (await owner.DeleteAsync($"{url}/{month.Expenses[0].Id}")).Content.ReadFromJsonAsync<ExpenseMonthBody>())!;
        month.Expenses.Should().ContainSingle();
    }
}
