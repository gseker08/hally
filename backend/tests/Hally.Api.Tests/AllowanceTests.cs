using System.Net;
using System.Net.Http.Json;
using FluentAssertions;
using Hally.Api.Features.Allowance;
using Hally.Domain.Allowance;
using Hally.Domain.Notifications;
using Hally.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;

namespace Hally.Api.Tests;

public record AllowanceSettingsBody(int RateCherries, decimal RateAmount, string Currency, int WeeklyCherries, bool AddToExpenses);
public record SavingsGoalBody(string Title, string Emoji, int Cherries);
public record AllowanceRequestBody(Guid Id, Guid ChildId, string ChildName, int Cherries, decimal Amount, string Currency, string Status, DateTimeOffset CreatedAt,
    string? DecidedByName, DateTimeOffset? DecidedAt);
public record LedgerLineBody(string Kind, string Title, int Points, DateOnly Day);
public record ChildSavingsBody(int Balance, SavingsGoalBody? Goal, int? WeeksToGoal, AllowanceSettingsBody Settings, AllowanceRequestBody? Pending, List<LedgerLineBody> Recent);
public record AllowanceBody(AllowanceSettingsBody Settings, SavingsGoalBody? Goal, int Balance, List<AllowanceRequestBody> Requests);
public record ExpenseLineBody(string Title, decimal Amount, Guid? ChildId);
public record ExpenseMonthLinesBody(List<ExpenseLineBody> Expenses);

[Collection(ApiCollection.Name)]
public class AllowanceTests(HallyApiFactory api)
{
    private static string Email() => $"{Guid.NewGuid():N}@example.com";

    private async Task<(HttpClient Ayse, HttpClient Zeynep, string F, Guid FamilyId, Guid ChildId, HttpClient Kid)> FamilyAsync(int cherries)
    {
        var ayse = await api.SignInAsync(Email(), "Ayşe Yılmaz");
        var family = (await (await ayse.PostIdempotentAsync("/api/v1/families", new { name = "Yılmaz" })).Content.ReadFromJsonAsync<FamilyBody>())!;
        var f = $"/api/v1/families/{family.Id}";
        var careInvite = (await (await ayse.PostIdempotentAsync($"{f}/invitations", new { role = "caregiver" })).Content.ReadFromJsonAsync<RoleInvitationBody>())!;
        var zeynep = await api.SignInAsync(Email(), "Zeynep");
        await zeynep.PostIdempotentAsync($"/api/v1/invitations/{careInvite.Token}/accept", null);
        var child = (await (await ayse.PostIdempotentAsync($"{f}/children", new { firstName = "Ela" })).Content.ReadFromJsonAsync<ChildBody>())!;
        var code = (await (await ayse.PostAsync($"{f}/children/{child.Id}/pairing-code", null)).Content.ReadFromJsonAsync<PairingCodeBody>())!;
        var paired = (await (await api.CreateClient().PostAsJsonAsync("/api/v1/child/pair", new { code = code.Code })).Content.ReadFromJsonAsync<PairResultBody>())!;
        var kid = api.CreateClient();
        kid.DefaultRequestHeaders.Add("X-Hally-Child", paired.Token);
        if (cherries > 0)
        {
            await ayse.PutAsJsonAsync($"{f}/child-mode", new { requireApproval = false });
            for (var i = 0; i < cherries / 30; i++)
            {
                var chore = (await (await ayse.PostAsJsonAsync($"{f}/chores", new { title = $"Odanı topla {i}", points = 30 })).Content.ReadFromJsonAsync<ChoreBody>())!;
                (await kid.PostAsync($"/api/v1/child/chores/{chore.Id}/done", null)).EnsureSuccessStatusCode();
            }
        }

        return (ayse, zeynep, f, family.Id, child.Id, kid);
    }

    [Fact]
    public async Task The_child_asks_to_convert_and_Odedim_takes_the_cherries_and_writes_the_expense()
    {
        var (ayse, zeynep, f, familyId, childId, kid) = await FamilyAsync(60);
        var url = $"{f}/children/{childId}/allowance";
        var plan = (await ayse.GetFromJsonAsync<AllowanceBody>(url))!;
        plan.Settings.Should().Be(new AllowanceSettingsBody(10, 5m, "TRY", 0, true));
        plan.Balance.Should().Be(60);
        (await zeynep.GetAsync(url)).StatusCode.Should().Be(HttpStatusCode.Forbidden, "caregivers don't see money");

        (await kid.PostAsJsonAsync("/api/v1/child/savings/convert", new { cherries = 45 })).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity, "whole steps of 10");
        (await kid.PostAsJsonAsync("/api/v1/child/savings/convert", new { cherries = 70 })).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity, "only 60 in the jar");
        var savings = (await (await kid.PostAsJsonAsync("/api/v1/child/savings/convert", new { cherries = 40 })).Content.ReadFromJsonAsync<ChildSavingsBody>())!;
        savings.Pending!.Should().Match<AllowanceRequestBody>(r => r.Cherries == 40 && r.Amount == 20m && r.Status == "Pending");
        savings.Balance.Should().Be(60, "nothing leaves the jar until a parent pays");
        (await kid.PostAsJsonAsync("/api/v1/child/savings/convert", new { cherries = 10 })).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity, "one waits already");

        using (var scope = api.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<HallyDbContext>();
            var n = await db.Notifications.SingleAsync(x => x.FamilyId == familyId && x.Kind == NotificationKind.AllowanceRequest);
            n.Title.Should().Be("Ela harçlık istiyor");
            n.Body.Should().Be("40 kiraz = 20 ₺");
        }

        var open = (await ayse.GetFromJsonAsync<List<AllowanceRequestBody>>($"{f}/allowance-requests"))!.Should().ContainSingle().Which;
        var paid = (await (await ayse.PostAsJsonAsync($"{f}/allowance-requests/{open.Id}/decide", new { paid = true })).Content.ReadFromJsonAsync<AllowanceRequestBody>())!;
        paid.Should().Match<AllowanceRequestBody>(r => r.Status == "Paid" && r.DecidedByName == "Ayşe");
        (await ayse.PostAsJsonAsync($"{f}/allowance-requests/{open.Id}/decide", new { paid = true })).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);

        savings = (await kid.GetFromJsonAsync<ChildSavingsBody>("/api/v1/child/savings"))!;
        savings.Balance.Should().Be(20);
        savings.Pending.Should().BeNull();
        savings.Recent.First().Should().Match<LedgerLineBody>(l => l.Kind == "Allowance" && l.Title == "converted" && l.Points == -40);

        using (var scope = api.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<HallyDbContext>();
            var expense = await db.Expenses.SingleAsync(e => e.FamilyId == familyId);
            expense.Title.Should().Be("Harçlık · Ela");
            expense.Amount.Should().Be(20m);
            expense.ChildId.Should().Be(childId);
        }

        // "Şimdi değil" leaves the jar alone.
        await kid.PostAsJsonAsync("/api/v1/child/savings/convert", new { cherries = 20 });
        var next = (await ayse.GetFromJsonAsync<List<AllowanceRequestBody>>($"{f}/allowance-requests"))!.Single();
        (await (await ayse.PostAsJsonAsync($"{f}/allowance-requests/{next.Id}/decide", new { paid = false })).Content.ReadFromJsonAsync<AllowanceRequestBody>())!
            .Status.Should().Be("Declined");
        (await kid.GetFromJsonAsync<ChildSavingsBody>("/api/v1/child/savings"))!.Balance.Should().Be(20);
    }

    [Fact]
    public async Task Parents_set_the_rate_and_weekly_allowance_which_arrives_once_a_week_and_does_not_count_as_earned()
    {
        var (ayse, _, f, familyId, childId, kid) = await FamilyAsync(0);
        var url = $"{f}/children/{childId}/allowance";
        (await ayse.PutAsJsonAsync(url, new { rateCherries = 10, rateAmount = 5.555m, currency = "TRY", weeklyCherries = 20, addToExpenses = false })).StatusCode
            .Should().Be(HttpStatusCode.UnprocessableEntity);
        var saved = (await (await ayse.PutAsJsonAsync(url, new { rateCherries = 20, rateAmount = 5m, currency = "TRY", weeklyCherries = 20, addToExpenses = false }))
            .Content.ReadFromJsonAsync<AllowanceBody>())!;
        saved.Settings.Should().Be(new AllowanceSettingsBody(20, 5m, "TRY", 20, false));

        using (var scope = api.Services.CreateScope())
        {
            var job = scope.ServiceProvider.GetRequiredService<AllowanceService>();
            (await job.WeeklyAsync(CancellationToken.None)).Should().BeGreaterThan(0);
        }

        using (var scope = api.Services.CreateScope())
        {
            var job = scope.ServiceProvider.GetRequiredService<AllowanceService>();
            await job.WeeklyAsync(CancellationToken.None);
            var db = scope.ServiceProvider.GetRequiredService<HallyDbContext>();
            (await db.PointEntries.CountAsync(p => p.ChildId == childId)).Should().Be(1, "once per week");
        }

        var savings = (await kid.GetFromJsonAsync<ChildSavingsBody>("/api/v1/child/savings"))!;
        savings.Balance.Should().Be(20);
        savings.Recent.Single().Should().Match<LedgerLineBody>(l => l.Kind == "Allowance" && l.Title == "weekly" && l.Points == 20);
        (await kid.GetFromJsonAsync<ChildWeekBody>("/api/v1/child/home"))!.WeekCherries.Should().Be(0, "allowance is not earned");

        await kid.PostAsJsonAsync("/api/v1/child/savings/convert", new { cherries = 20 });
        var open = (await ayse.GetFromJsonAsync<List<AllowanceRequestBody>>($"{f}/allowance-requests"))!.Single();
        open.Amount.Should().Be(5m);
        await ayse.PostAsJsonAsync($"{f}/allowance-requests/{open.Id}/decide", new { paid = true });
        using (var scope = api.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<HallyDbContext>();
            (await db.Expenses.AnyAsync(e => e.FamilyId == familyId)).Should().BeFalse("the family turned Harcamalar off");
        }
    }

    [Fact]
    public async Task The_child_sets_a_savings_goal_with_an_estimate()
    {
        var (_, _, _, _, _, kid) = await FamilyAsync(30);
        (await kid.PutAsJsonAsync("/api/v1/child/savings/goal", new { title = "", emoji = "🚲", cherries = 300 })).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
        var savings = (await (await kid.PutAsJsonAsync("/api/v1/child/savings/goal", new { title = "Bisiklet", emoji = "🚲", cherries = 300 }))
            .Content.ReadFromJsonAsync<ChildSavingsBody>())!;
        savings.Goal.Should().Be(new SavingsGoalBody("Bisiklet", "🚲", 300));
        // 30 cherries in the last four weeks = 7.5 a week; 270 to go = 36 weeks.
        savings.WeeksToGoal.Should().Be(36);

        savings = (await (await kid.DeleteAsync("/api/v1/child/savings/goal")).Content.ReadFromJsonAsync<ChildSavingsBody>())!;
        savings.Goal.Should().BeNull();
        savings.WeeksToGoal.Should().BeNull();
    }

    [Fact]
    public void Conversion_goes_in_whole_steps()
    {
        var plan = new AllowancePlan(Guid.NewGuid(), Guid.NewGuid(), DateTimeOffset.UtcNow);
        plan.AmountFor(40).Should().Be(20m);
        plan.Invoking(p => p.AmountFor(5)).Should().Throw<Hally.Domain.Common.DomainException>();
        AllowanceService.Money(20m, "TRY", "tr").Should().Be("20 ₺");
        AllowanceService.Money(2.5m, "TRY", "tr").Should().Be("2,50 ₺");
        var monday = new DateOnly(2026, 11, 23);
        plan.TakeWeek(monday).Should().BeFalse("no weekly allowance set");
        plan.Update(10, 5m, "TRY", 20, true);
        plan.TakeWeek(monday).Should().BeTrue();
        plan.TakeWeek(monday).Should().BeFalse();
        plan.TakeWeek(monday.AddDays(7)).Should().BeTrue();
    }
}

public record ChildWeekBody(int WeekCherries);
