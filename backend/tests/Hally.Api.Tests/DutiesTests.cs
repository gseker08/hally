using System.Net;
using System.Net.Http.Json;
using FluentAssertions;

namespace Hally.Api.Tests;

public record DutySlotBody(string Kind, bool Assigned, Guid? AssigneeUserId, string? AssigneeName, TimeOnly? Time, bool IsChange,
    DateTimeOffset? DoneAt, string? DoneByName);
public record DutyDayBody(DateOnly Date, DutySlotBody DropOff, DutySlotBody PickUp);
public record DutyAdultBody(Guid UserId, string Name);
public record DutyWeekBody(DateOnly Start, DateOnly Today, List<DutyDayBody> Days, List<DutyAdultBody> Adults);

[Collection(ApiCollection.Name)]
public class DutiesTests(HallyApiFactory api)
{
    [Fact]
    public async Task Usual_plan_changes_for_a_date_and_done_tells_the_other_parent()
    {
        var owner = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Ayşe Yılmaz");
        var family = (await (await owner.PostIdempotentAsync("/api/v1/families", new { name = "Yılmaz" })).Content.ReadFromJsonAsync<FamilyBody>())!;
        var invite = (await (await owner.PostIdempotentAsync($"/api/v1/families/{family.Id}/invitations", null)).Content.ReadFromJsonAsync<InvitationBody>())!;
        var partner = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Mehmet");
        await partner.PostIdempotentAsync($"/api/v1/invitations/{invite.Token}/accept", null);
        await partner.PutAsJsonAsync("/api/v1/me/devices", new { platform = "android", token = $"tok-{Guid.NewGuid():N}" });
        var url = $"/api/v1/families/{family.Id}/duties";

        var week = (await owner.GetFromJsonAsync<DutyWeekBody>(url))!;
        week.Days.Should().HaveCount(7);
        week.Start.DayOfWeek.Should().Be(DayOfWeek.Monday);
        var ayse = week.Adults.Single(a => a.Name == "Ayşe Yılmaz").UserId;
        var mehmet = week.Adults.Single(a => a.Name == "Mehmet").UserId;

        // Every weekday Ayşe drops off at 08:15, Mehmet picks up.
        for (var d = 0; d < 5; d++)
        {
            (await owner.PutAsJsonAsync($"{url}/rules/{d}/DropOff", new { assigneeUserId = ayse, time = "08:15:00" })).StatusCode.Should().Be(HttpStatusCode.OK);
            await owner.PutAsJsonAsync($"{url}/rules/{d}/PickUp", new { assigneeUserId = mehmet });
        }

        week = (await owner.GetFromJsonAsync<DutyWeekBody>(url))!;
        week.Days[0].DropOff.AssigneeName.Should().Be("Ayşe Yılmaz");
        week.Days[0].DropOff.Time.Should().Be(new TimeOnly(8, 15));
        week.Days[5].PickUp.Assigned.Should().BeFalse("no school on Saturday");

        // Thursday: grandma picks up.
        var thursday = week.Start.AddDays(3);
        week = (await (await partner.PutAsJsonAsync($"{url}/{thursday:yyyy-MM-dd}/PickUp", new { assigneeName = " Babaanne " })).Content.ReadFromJsonAsync<DutyWeekBody>())!;
        week.Days[3].PickUp.AssigneeName.Should().Be("Babaanne");
        week.Days[3].PickUp.IsChange.Should().BeTrue();
        week = (await (await partner.DeleteAsync($"{url}/{thursday:yyyy-MM-dd}/PickUp")).Content.ReadFromJsonAsync<DutyWeekBody>())!;
        week.Days[3].PickUp.AssigneeName.Should().Be("Mehmet");

        (await owner.PutAsJsonAsync($"{url}/rules/0/DropOff", new { assigneeUserId = Guid.NewGuid() })).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);

        var before = api.Push.Sent.Count;
        await owner.PostAsync($"{url}/today/DropOff/done", null);
        week = (await (await owner.PostAsync($"{url}/today/DropOff/done", null)).Content.ReadFromJsonAsync<DutyWeekBody>())!;
        var today = week.Days.Single(d => d.Date == week.Today);
        today.DropOff.DoneByName.Should().Be("Ayşe Yılmaz");
        api.Push.Sent.Skip(before).Should().ContainSingle(p => p.Message.Title == "Okula bırakıldı").Which.Message.Body.Should().Be("Ayşe çocukları okula bıraktı.");

        week = (await (await owner.DeleteAsync($"{url}/today/DropOff/done")).Content.ReadFromJsonAsync<DutyWeekBody>())!;
        week.Days.Single(d => d.Date == week.Today).DropOff.DoneAt.Should().BeNull();
    }
}
