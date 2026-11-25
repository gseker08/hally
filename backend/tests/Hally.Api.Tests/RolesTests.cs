using System.Net;
using System.Net.Http.Json;
using FluentAssertions;
using Hally.Api.Features.Privacy;
using Hally.Domain.Common;
using Hally.Domain.Families;
using Hally.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;

namespace Hally.Api.Tests;

public record RoleInvitationBody(Guid Id, string Token, string Url, string ShareText, string Role);
public record AccessMemberBody(Guid UserId, string DisplayName, string Role, DateTimeOffset? AccessUntil, List<Guid> ChildIds, bool CanSeeHealth);
public record ScopedFamilyBody(Guid Id, List<AccessMemberBody> Members, List<ChildBody> Children);

[Collection(ApiCollection.Name)]
public class RolesTests(HallyApiFactory api)
{
    private static string Email() => $"{Guid.NewGuid():N}@example.com";

    private async Task<(HttpClient Parent, HttpClient Caregiver, FamilyBody Family)> FamilyWithCaregiverAsync()
    {
        var parent = await api.SignInAsync(Email(), "Ayşe");
        var family = (await (await parent.PostIdempotentAsync("/api/v1/families", new { name = "Yılmaz" })).Content.ReadFromJsonAsync<FamilyBody>())!;
        var res = await parent.PostIdempotentAsync($"/api/v1/families/{family.Id}/invitations", new { role = "caregiver" });
        res.StatusCode.Should().Be(HttpStatusCode.Created);
        var invite = (await res.Content.ReadFromJsonAsync<RoleInvitationBody>())!;
        invite.Role.Should().Be("caregiver");
        invite.ShareText.Should().Contain("bakıcı");

        var preview = await api.CreateClient().GetFromJsonAsync<Dictionary<string, object>>($"/api/v1/invitations/{invite.Token}");
        preview!["role"].ToString().Should().Be("caregiver");

        var caregiver = await api.SignInAsync(Email(), "Zeynep");
        (await caregiver.PostIdempotentAsync($"/api/v1/invitations/{invite.Token}/accept", null)).StatusCode.Should().Be(HttpStatusCode.OK);
        return (parent, caregiver, family);
    }

    [Fact]
    public async Task Caregiver_joins_with_the_caregiver_role()
    {
        var (parent, caregiver, family) = await FamilyWithCaregiverAsync();

        var members = await parent.GetFromJsonAsync<List<MemberBody>>($"/api/v1/families/{family.Id}/members");
        members!.Select(m => (m.DisplayName, m.Role)).Should().Equal(("Ayşe", "Owner"), ("Zeynep", "Caregiver"));
        var me = await caregiver.GetFromJsonAsync<MeBody>("/api/v1/me");
        me!.Families.Should().ContainSingle(f => f.Id == family.Id && f.Role == "Caregiver");

        // A parent invitation still works the old way, with or without a body.
        var plain = (await (await parent.PostIdempotentAsync($"/api/v1/families/{family.Id}/invitations", null)).Content.ReadFromJsonAsync<RoleInvitationBody>())!;
        plain.Role.Should().Be("parent");
        (await parent.PostIdempotentAsync($"/api/v1/families/{family.Id}/invitations", new { role = "boss" })).StatusCode
            .Should().Be(HttpStatusCode.UnprocessableEntity);
    }

    [Fact]
    public async Task Caregiver_helps_with_the_day_but_cannot_manage_the_family()
    {
        var (parent, caregiver, family) = await FamilyWithCaregiverAsync();
        var f = $"/api/v1/families/{family.Id}";
        var child = (await (await parent.PostIdempotentAsync($"{f}/children", new { firstName = "Ela" })).Content.ReadFromJsonAsync<ChildBody>())!;
        var task = (await (await parent.PostIdempotentAsync($"{f}/tasks", new { title = "Ela'yı okuldan al" })).Content.ReadFromJsonAsync<TaskBody>())!;

        // Allowed: seeing the day, completing tasks, logging care.
        (await caregiver.GetAsync(f)).StatusCode.Should().Be(HttpStatusCode.OK);
        (await caregiver.GetAsync($"{f}/today")).StatusCode.Should().Be(HttpStatusCode.OK);
        (await caregiver.GetAsync($"{f}/tasks")).StatusCode.Should().Be(HttpStatusCode.OK);
        (await caregiver.PostIdempotentAsync($"{f}/tasks/{task.Id}/complete", null)).StatusCode.Should().Be(HttpStatusCode.OK);
        (await caregiver.PostIdempotentAsync($"{f}/children/{child.Id}/screen-time/start", null)).IsSuccessStatusCode.Should().BeTrue();
        (await caregiver.PostIdempotentAsync($"{f}/children/{child.Id}/sleep/start", new { })).IsSuccessStatusCode.Should().BeTrue();
        (await caregiver.GetAsync($"{f}/shopping")).StatusCode.Should().Be(HttpStatusCode.OK);
        (await caregiver.GetAsync($"{f}/chats")).StatusCode.Should().Be(HttpStatusCode.OK);
        (await caregiver.GetAsync($"{f}/entitlements")).StatusCode.Should().Be(HttpStatusCode.OK);

        // Parents only: planning, family settings, invitations, billing, money, health, AI.
        (await caregiver.PostIdempotentAsync($"{f}/tasks", new { title = "x" })).StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await caregiver.PostIdempotentAsync($"{f}/children", new { firstName = "X" })).StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await caregiver.DeleteAsync($"{f}/children/{child.Id}")).StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await caregiver.PostIdempotentAsync($"{f}/invitations", null)).StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await caregiver.PostIdempotentAsync($"{f}/subscription/trial", null)).StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await caregiver.GetAsync($"{f}/expenses")).StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await caregiver.GetAsync($"{f}/children/{child.Id}/health")).StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await caregiver.PutAsJsonAsync($"{f}/children/{child.Id}/screen-time/goal", new { dailyMinutes = 60 })).StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await caregiver.PostIdempotentAsync($"{f}/assistant/messages", new { text = "merhaba" })).StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }

    [Fact]
    public async Task Caregivers_are_left_out_of_expense_splits()
    {
        var (parent, caregiver, family) = await FamilyWithCaregiverAsync();
        var url = $"/api/v1/families/{family.Id}/expenses";
        (await parent.PostAsJsonAsync(url, new { title = "Okul servisi", amount = 100m, category = "School" })).StatusCode.Should().Be(HttpStatusCode.Created);

        var month = (await parent.GetFromJsonAsync<ExpenseMonthBody>(url))!;
        month.Balances.Should().ContainSingle().Which.Name.Should().Be("Ayşe");
        month.Expenses.Single().MyShare.Should().Be(100m);
        _ = caregiver;
    }

    [Fact]
    public async Task When_the_last_parent_leaves_the_caregiver_loses_access()
    {
        var (parent, caregiver, family) = await FamilyWithCaregiverAsync();
        (await parent.PostIdempotentAsync($"/api/v1/families/{family.Id}/leave", null)).StatusCode.Should().Be(HttpStatusCode.NoContent);

        (await caregiver.GetAsync($"/api/v1/families/{family.Id}")).StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await caregiver.GetFromJsonAsync<MeBody>("/api/v1/me"))!.Families.Should().BeEmpty();
    }

    [Fact]
    public async Task Caregiver_leaving_keeps_the_family()
    {
        var (parent, caregiver, family) = await FamilyWithCaregiverAsync();
        (await caregiver.PostIdempotentAsync($"/api/v1/families/{family.Id}/leave", null)).StatusCode.Should().Be(HttpStatusCode.NoContent);

        var members = await parent.GetFromJsonAsync<List<MemberBody>>($"/api/v1/families/{family.Id}/members");
        members!.Should().ContainSingle().Which.Role.Should().Be("Owner");
    }

    [Fact]
    public void Caregivers_have_their_own_limit_and_never_become_owner()
    {
        var owner = Guid.NewGuid();
        var family = new Family("Yılmaz", "Europe/Istanbul", owner);
        var caregivers = Enumerable.Range(0, Family.MaxCaregivers).Select(_ => family.AddMember(Guid.NewGuid(), FamilyRole.Caregiver).UserId).ToList();
        var act = () => family.AddMember(Guid.NewGuid(), FamilyRole.Caregiver);
        act.Should().Throw<DomainException>().Which.Code.Should().Be("family.caregiver_limit");
        family.AddAdult(Guid.NewGuid()).IsParent.Should().BeTrue();

        var partner = family.Members.Single(m => m.Role == FamilyRole.Adult).UserId;
        family.RemoveMember(owner);
        family.MemberOf(partner)!.Role.Should().Be(FamilyRole.Owner);
        family.Members.Where(m => caregivers.Contains(m.UserId)).Should().OnlyContain(m => m.Role == FamilyRole.Caregiver);
        family.IsLastParent(partner).Should().BeTrue();
    }

    [Fact]
    public async Task Caregiver_sees_only_the_children_they_look_after()
    {
        var parent = await api.SignInAsync(Email(), "Ayşe");
        var family = (await (await parent.PostIdempotentAsync("/api/v1/families", new { name = "Yılmaz" })).Content.ReadFromJsonAsync<FamilyBody>())!;
        var f = $"/api/v1/families/{family.Id}";
        var ela = (await (await parent.PostIdempotentAsync($"{f}/children", new { firstName = "Ela" })).Content.ReadFromJsonAsync<ChildBody>())!;
        var deniz = (await (await parent.PostIdempotentAsync($"{f}/children", new { firstName = "Deniz" })).Content.ReadFromJsonAsync<ChildBody>())!;
        var until = api.Clock.GetUtcNow().AddDays(90);
        var invite = (await (await parent.PostIdempotentAsync($"{f}/invitations",
            new { role = "caregiver", childIds = new[] { ela.Id }, accessUntil = until })).Content.ReadFromJsonAsync<RoleInvitationBody>())!;
        var caregiver = await api.SignInAsync(Email(), "Zeynep");
        await caregiver.PostIdempotentAsync($"/api/v1/invitations/{invite.Token}/accept", null);

        await parent.PostIdempotentAsync($"{f}/tasks", new { title = "Ela yüzme", childIds = new[] { ela.Id } });
        await parent.PostIdempotentAsync($"{f}/tasks", new { title = "Deniz aşı", childIds = new[] { deniz.Id } });
        await parent.PostIdempotentAsync($"{f}/tasks", new { title = "Market" });

        var seen = (await caregiver.GetFromJsonAsync<ScopedFamilyBody>(f))!;
        seen.Children.Select(c => c.FirstName).Should().Equal("Ela");
        var me = seen.Members.Single(m => m.DisplayName == "Zeynep");
        me.ChildIds.Should().Equal(ela.Id);
        me.CanSeeHealth.Should().BeFalse();
        me.AccessUntil.Should().BeCloseTo(until, TimeSpan.FromSeconds(1));

        var tasks = (await caregiver.GetFromJsonAsync<List<TaskBody>>($"{f}/tasks"))!;
        tasks.Select(t => t.Title).Should().BeEquivalentTo("Ela yüzme", "Market");
        (await parent.GetFromJsonAsync<List<TaskBody>>($"{f}/tasks"))!.Should().HaveCount(3);
        (await caregiver.PostIdempotentAsync($"{f}/children/{deniz.Id}/screen-time/start", null)).StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await caregiver.PostIdempotentAsync($"{f}/children/{ela.Id}/screen-time/start", null)).IsSuccessStatusCode.Should().BeTrue();
        (await caregiver.GetFromJsonAsync<Dictionary<string, object>>($"{f}/screen-time"))!["children"].ToString().Should().NotContain(deniz.Id.ToString());

        // Health stays closed until a parent opens it.
        (await caregiver.GetAsync($"{f}/children/{ela.Id}/health")).StatusCode.Should().Be(HttpStatusCode.Forbidden);
        var userId = me.UserId;
        var put = await parent.PutAsJsonAsync($"{f}/members/{userId}/access", new { accessUntil = (DateTimeOffset?)null, childIds = Array.Empty<Guid>(), canSeeHealth = true });
        put.StatusCode.Should().Be(HttpStatusCode.OK);
        (await caregiver.GetAsync($"{f}/children/{ela.Id}/health")).StatusCode.Should().Be(HttpStatusCode.OK);
        (await caregiver.GetAsync($"{f}/children/{deniz.Id}/health")).StatusCode.Should().Be(HttpStatusCode.OK);
        (await caregiver.PutAsJsonAsync($"{f}/members/{userId}/access", new { canSeeHealth = true })).StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await parent.PutAsJsonAsync($"{f}/members/{userId}/access", new { childIds = new[] { Guid.NewGuid() } })).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
    }

    [Fact]
    public async Task Caregiver_access_ends_on_its_date_and_parents_can_remove_them()
    {
        var (parent, caregiver, family) = await FamilyWithCaregiverAsync();
        var f = $"/api/v1/families/{family.Id}";
        var userId = (await caregiver.GetFromJsonAsync<MeBody>("/api/v1/me"))!.Id;

        using (var scope = api.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<HallyDbContext>();
            var past = api.Clock.GetUtcNow().AddMinutes(-1);
            await db.FamilyMembers.Where(m => m.FamilyId == family.Id && m.UserId == userId)
                .ExecuteUpdateAsync(u => u.SetProperty(m => m.AccessUntil, past));
        }

        (await caregiver.GetAsync(f)).StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await caregiver.GetFromJsonAsync<MeBody>("/api/v1/me"))!.Families.Should().BeEmpty();

        using (var scope = api.Services.CreateScope())
        {
            (await scope.ServiceProvider.GetRequiredService<CaregiverExpiryJob>().RunAsync(CancellationToken.None)).Should().BeGreaterThan(0);
        }

        (await parent.GetFromJsonAsync<List<MemberBody>>($"{f}/members"))!.Should().ContainSingle();

        // A parent removes a caregiver directly; parents cannot be removed this way.
        var (parent2, caregiver2, family2) = await FamilyWithCaregiverAsync();
        var parentId = (await parent2.GetFromJsonAsync<MeBody>("/api/v1/me"))!.Id;
        var caregiverId = (await caregiver2.GetFromJsonAsync<MeBody>("/api/v1/me"))!.Id;
        (await caregiver2.DeleteAsync($"/api/v1/families/{family2.Id}/members/{parentId}")).StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await parent2.DeleteAsync($"/api/v1/families/{family2.Id}/members/{parentId}")).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
        (await parent2.DeleteAsync($"/api/v1/families/{family2.Id}/members/{caregiverId}")).StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await caregiver2.GetAsync($"/api/v1/families/{family2.Id}")).StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }
}
