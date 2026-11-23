using System.Net;
using System.Net.Http.Json;
using FluentAssertions;
using Hally.Api.Features.Health;

namespace Hally.Api.Tests;

public record HealthProfileBody(string? BloodType, string? Allergies, string? Conditions, string? DoctorName, string? DoctorPhone, string? Notes,
    DateTimeOffset? UpdatedAt);
public record VaccineBody(Guid Id, string Name, DateOnly? DueOn, DateOnly? GivenOn, string? Note, bool Overdue);
public record GrowthBody(Guid Id, DateOnly MeasuredOn, decimal? HeightCm, decimal? WeightKg, decimal? HeadCm);
public record AppointmentBody(Guid Id, Guid EventId, string Title, DateTimeOffset StartsAt, string? Location, string? Doctor, bool Past);
public record HealthCardBody(Guid ChildId, HealthProfileBody Profile, List<VaccineBody> Vaccines, List<GrowthBody> Growth, List<AppointmentBody> Appointments);

[Collection(ApiCollection.Name)]
public class HealthCardTests(HallyApiFactory api)
{
    [Fact]
    public void Reminder_is_the_evening_before_or_two_hours_before()
    {
        const string tz = "Europe/Istanbul";
        var at = new DateTimeOffset(2026, 12, 10, 10, 30, 0, TimeSpan.FromHours(3));
        HealthCardController.ReminderTime(at, tz, at.AddDays(-5))
            .Should().Be(new DateTimeOffset(2026, 12, 9, 19, 0, 0, TimeSpan.FromHours(3)));
        HealthCardController.ReminderTime(at, tz, new DateTimeOffset(2026, 12, 9, 22, 0, 0, TimeSpan.FromHours(3)))
            .Should().Be(at.AddHours(-2));
        HealthCardController.ReminderTime(at, tz, at.AddHours(-1)).Should().BeNull();
    }

    [Fact]
    public async Task Parents_keep_a_childs_health_card()
    {
        var owner = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Ayşe");
        var family = (await (await owner.PostIdempotentAsync("/api/v1/families", new { name = "Yılmaz" })).Content.ReadFromJsonAsync<FamilyBody>())!;
        var ela = (await (await owner.PostIdempotentAsync($"/api/v1/families/{family.Id}/children", new { firstName = "Ela" })).Content.ReadFromJsonAsync<ChildBody>())!;
        var url = $"/api/v1/families/{family.Id}/children/{ela.Id}/health";

        var card = (await owner.GetFromJsonAsync<HealthCardBody>(url))!;
        card.Profile.BloodType.Should().BeNull();
        card.Vaccines.Should().BeEmpty();

        var saved = await owner.PutAsJsonAsync($"{url}/profile", new { bloodType = "A+", allergies = "Penisilin, fıstık", doctorName = "Dr. Kaya", doctorPhone = "0212 555 00 00" });
        saved.StatusCode.Should().Be(HttpStatusCode.OK);
        card = (await saved.Content.ReadFromJsonAsync<HealthCardBody>())!;
        card.Profile.Allergies.Should().Be("Penisilin, fıstık");
        (await owner.PutAsJsonAsync($"{url}/profile", new { bloodType = "C+" })).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);

        var today = DateOnly.FromDateTime(DateTime.UtcNow);
        await owner.PostAsJsonAsync($"{url}/vaccines", new { name = "KKK", givenOn = today.AddMonths(-2) });
        await owner.PostAsJsonAsync($"{url}/vaccines", new { name = "Hepatit A", dueOn = today.AddDays(-3) });
        var added = await owner.PostAsJsonAsync($"{url}/vaccines", new { name = "Grip", dueOn = today.AddDays(20) });
        added.StatusCode.Should().Be(HttpStatusCode.Created);
        card = (await added.Content.ReadFromJsonAsync<HealthCardBody>())!;
        card.Vaccines.Select(v => v.Name).Should().Equal("Hepatit A", "Grip", "KKK");
        card.Vaccines[0].Overdue.Should().BeTrue();
        (await owner.PostAsJsonAsync($"{url}/vaccines", new { name = "x" })).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);

        card = (await (await owner.PostAsJsonAsync($"{url}/vaccines/{card.Vaccines[0].Id}/given", new { })).Content.ReadFromJsonAsync<HealthCardBody>())!;
        card.Vaccines.Select(v => v.Name).Should().Equal("Grip", "Hepatit A", "KKK");
        card.Vaccines[1].Overdue.Should().BeFalse();

        await owner.PostAsJsonAsync($"{url}/growth", new { heightCm = 98.5m, weightKg = 15.2m, measuredOn = today.AddMonths(-6) });
        card = (await (await owner.PostAsJsonAsync($"{url}/growth", new { heightCm = 102m })).Content.ReadFromJsonAsync<HealthCardBody>())!;
        card.Growth.Select(g => g.HeightCm).Should().Equal(98.5m, 102m);
        (await owner.PostAsJsonAsync($"{url}/growth", new { })).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
        (await owner.PostAsJsonAsync($"{url}/growth", new { heightCm = 500 })).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);

        var startsAt = DateTimeOffset.UtcNow.AddDays(3);
        var appt = await owner.PostAsJsonAsync($"{url}/appointments", new { title = "Diş kontrolü", startsAt, location = "Moda Klinik", doctor = "Dr. Demir" });
        appt.StatusCode.Should().Be(HttpStatusCode.Created);
        card = (await appt.Content.ReadFromJsonAsync<HealthCardBody>())!;
        var a = card.Appointments.Should().ContainSingle().Subject;
        a.Doctor.Should().Be("Dr. Demir");
        a.Past.Should().BeFalse();

        // It is an ordinary calendar event for the child.
        var events = await owner.GetStringAsync($"/api/v1/families/{family.Id}/events?from={startsAt.AddDays(-1):O}&to={startsAt.AddDays(1):O}".Replace("+", "%2B"));
        events.Should().Contain("Diş kontrolü");

        card = (await (await owner.DeleteAsync($"{url}/appointments/{a.Id}")).Content.ReadFromJsonAsync<HealthCardBody>())!;
        card.Appointments.Should().BeEmpty();

        var stranger = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "X");
        (await stranger.GetAsync(url)).StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }
}
