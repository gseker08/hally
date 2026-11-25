using System.Net;
using System.Net.Http.Json;
using FluentAssertions;

namespace Hally.Api.Tests;

public record BalanceMemberBody(Guid UserId, string Name, string Role, int Tasks, int SchoolRuns, int Feedings, int Shopping, int Medications, int Total);
public record BalanceSuggestionBody(Guid HeavyUserId, string HeavyName, int SharePercent, Guid ToUserId, string ToName, DateOnly? Date, string? Kind);
public record BalanceBody(DateOnly From, DateOnly To, DateOnly Today, int Total, List<BalanceMemberBody> Members, BalanceSuggestionBody? Suggestion);

[Collection(ApiCollection.Name)]
public class BalanceTests(HallyApiFactory api)
{
    private static string Email() => $"{Guid.NewGuid():N}@example.com";

    [Fact]
    public async Task Counts_who_did_what_this_week_and_suggests_handing_over_a_school_run()
    {
        var ayse = await api.SignInAsync(Email(), "Ayşe");
        var family = (await (await ayse.PostIdempotentAsync("/api/v1/families", new { name = "Yılmaz" })).Content.ReadFromJsonAsync<FamilyBody>())!;
        var f = $"/api/v1/families/{family.Id}";
        var invite = (await (await ayse.PostIdempotentAsync($"{f}/invitations", null)).Content.ReadFromJsonAsync<InvitationBody>())!;
        var mehmet = await api.SignInAsync(Email(), "Mehmet");
        await mehmet.PostIdempotentAsync($"/api/v1/invitations/{invite.Token}/accept", null);
        var careInvite = (await (await ayse.PostIdempotentAsync($"{f}/invitations", new { role = "caregiver" })).Content.ReadFromJsonAsync<RoleInvitationBody>())!;
        var zeynep = await api.SignInAsync(Email(), "Zeynep");
        await zeynep.PostIdempotentAsync($"/api/v1/invitations/{careInvite.Token}/accept", null);
        var child = (await (await ayse.PostIdempotentAsync($"{f}/children", new { firstName = "Ela" })).Content.ReadFromJsonAsync<ChildBody>())!;

        // Empty week: everyone listed with zeros, no suggestion.
        var empty = (await ayse.GetFromJsonAsync<BalanceBody>($"{f}/balance"))!;
        empty.Members.Select(m => (m.Name, m.Role)).Should().Equal(("Ayşe", "Parent"), ("Mehmet", "Parent"), ("Zeynep", "Caregiver"));
        empty.Total.Should().Be(0);
        empty.Suggestion.Should().BeNull();
        empty.From.DayOfWeek.Should().Be(DayOfWeek.Monday);
        empty.To.Should().Be(empty.Today);

        async Task CompleteTask(HttpClient who, string title)
        {
            var task = (await (await ayse.PostIdempotentAsync($"{f}/tasks", new { title })).Content.ReadFromJsonAsync<TaskBody>())!;
            (await who.PostIdempotentAsync($"{f}/tasks/{task.Id}/complete", null)).StatusCode.Should().Be(HttpStatusCode.OK);
        }

        for (var i = 0; i < 4; i++)
        {
            await CompleteTask(ayse, $"Görev {i}");
        }

        await CompleteTask(mehmet, "Çöpü çıkar");

        await ayse.PostAsJsonAsync($"{f}/shopping/items", new { text = "Süt, ekmek" });
        var list = (await ayse.GetFromJsonAsync<ShoppingListBody>($"{f}/shopping"))!;
        foreach (var item in list.Open)
        {
            await ayse.PatchAsJsonAsync($"{f}/shopping/items/{item.Id}", new { @checked = true });
        }

        (await zeynep.PostAsJsonAsync($"{f}/children/{child.Id}/feeding", new { kind = "Bottle", amountMl = 120 })).IsSuccessStatusCode.Should().BeTrue();
        var med = (await (await ayse.PostIdempotentAsync($"{f}/medications", new { childId = child.Id, name = "Şurup", minIntervalMinutes = 360 }))
            .Content.ReadFromJsonAsync<MedicationBody>())!;
        (await ayse.PostAsJsonAsync($"{f}/medications/{med.Id}/doses", new { })).StatusCode.Should().Be(HttpStatusCode.Created);

        // Ayşe drops off every day; Ayşe marks today's drop-off done.
        var week = (await ayse.GetFromJsonAsync<DutyWeekBody>($"{f}/duties"))!;
        var ayseId = week.Adults.Single(a => a.Name == "Ayşe").UserId;
        var mehmetId = week.Adults.Single(a => a.Name == "Mehmet").UserId;
        for (var d = 0; d < 7; d++)
        {
            await ayse.PutAsJsonAsync($"{f}/duties/rules/{d}/DropOff", new { assigneeUserId = ayseId });
        }

        await ayse.PostAsync($"{f}/duties/today/DropOff/done", null);

        var balance = (await ayse.GetFromJsonAsync<BalanceBody>($"{f}/balance"))!;
        var a = balance.Members.Single(m => m.Name == "Ayşe");
        (a.Tasks, a.SchoolRuns, a.Shopping, a.Medications, a.Feedings, a.Total).Should().Be((4, 1, 2, 1, 0, 8));
        balance.Members.Single(m => m.Name == "Mehmet").Total.Should().Be(1);
        balance.Members.Single(m => m.Name == "Zeynep").Feedings.Should().Be(1);
        balance.Total.Should().Be(10);

        var s = balance.Suggestion!;
        (s.HeavyUserId, s.ToUserId, s.SharePercent).Should().Be((ayseId, mehmetId, 80));
        s.Date.Should().Be(balance.Today.AddDays(1));
        s.Kind.Should().Be("DropOff");

        // Past weeks show counts but never a suggestion.
        var last = (await ayse.GetFromJsonAsync<BalanceBody>($"{f}/balance?from={balance.From.AddDays(-7):yyyy-MM-dd}&to={balance.From.AddDays(-1):yyyy-MM-dd}"))!;
        last.Total.Should().Be(0);
        last.Suggestion.Should().BeNull();

        (await ayse.GetAsync($"{f}/balance?from=2026-01-01&to=2026-03-01")).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
        (await zeynep.GetAsync($"{f}/balance")).StatusCode.Should().Be(HttpStatusCode.Forbidden, "caregivers cannot open the balance page");
    }
}
