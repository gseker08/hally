using System.Net;
using System.Net.Http.Json;
using FluentAssertions;
using Hally.Domain.Bedtime;
using Hally.Domain.Common;
using Hally.Domain.Notifications;
using Hally.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;

namespace Hally.Api.Tests;

public record BedtimeStepBody(string Title, string Emoji);
public record BedtimeRoutineBody(string Time, List<BedtimeStepBody> Steps, bool Enabled, bool LockUntilMorning, int Cherries);
public record BedtimeTonightBody(DateOnly Evening, int Done, int Total, DateTimeOffset? FinishedAt);
public record BedtimeBody(BedtimeRoutineBody? Routine, BedtimeTonightBody? Tonight);
public record ChildBedtimeBody(string Time, List<BedtimeStepBody> Steps, DateOnly Evening, bool Open, int Done, DateTimeOffset? FinishedAt, int Cherries, bool LockUntilMorning);
public record ChildScreenNightBody(bool Locked, bool Bedtime);

[Collection(ApiCollection.Name)]
public class BedtimeTests(HallyApiFactory api)
{
    /// <summary>A zone where it is evening (19:00-22:59) right now, so the routine is open whenever the suite runs.</summary>
    private string EveningZone() => TimeZoneInfo.GetSystemTimeZones().Select(z => z.Id).Where(FamilyTimeZone.IsValid)
        .First(z => FamilyTimeZone.ToFamilyTime(api.Clock.GetUtcNow(), z).Hour is >= 19 and < 23);

    [Fact]
    public async Task The_child_checks_the_steps_in_order_then_parents_hear_and_the_phone_sleeps()
    {
        var zone = EveningZone();
        var parent = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Ayşe");
        var family = (await (await parent.PostIdempotentAsync("/api/v1/families", new { name = "Yılmaz", timeZoneId = zone })).Content.ReadFromJsonAsync<FamilyBody>())!;
        var f = $"/api/v1/families/{family.Id}";
        var child = (await (await parent.PostIdempotentAsync($"{f}/children", new { firstName = "Ela" })).Content.ReadFromJsonAsync<ChildBody>())!;
        var code = (await (await parent.PostAsync($"{f}/children/{child.Id}/pairing-code", null)).Content.ReadFromJsonAsync<PairingCodeBody>())!;
        var paired = (await (await api.CreateClient().PostAsJsonAsync("/api/v1/child/pair", new { code = code.Code })).Content.ReadFromJsonAsync<PairResultBody>())!;
        var kid = api.CreateClient();
        kid.DefaultRequestHeaders.Add("X-Hally-Child", paired.Token);

        (await kid.GetAsync("/api/v1/child/bedtime")).StatusCode.Should().Be(HttpStatusCode.NoContent);
        var url = $"{f}/children/{child.Id}/bedtime";
        (await parent.GetFromJsonAsync<BedtimeBody>(url))!.Routine.Should().BeNull();

        var now = FamilyTimeZone.ToFamilyTime(api.Clock.GetUtcNow(), zone);
        var time = $"{now:HH:mm}";
        var steps = new[] { new { title = "Pijamalarını giy", emoji = "👕" }, new { title = "Dişlerini fırçala", emoji = "🪥" }, new { title = "Yatağına gir", emoji = "🛏️" } };
        (await parent.PutAsJsonAsync(url, new { time = "14:00", steps, enabled = true, lockUntilMorning = true, cherries = 3 })).StatusCode
            .Should().Be(HttpStatusCode.UnprocessableEntity, "bedtime is in the evening");
        (await parent.PutAsJsonAsync(url, new { time, steps = Array.Empty<object>(), enabled = true, lockUntilMorning = true, cherries = 3 })).StatusCode
            .Should().Be(HttpStatusCode.UnprocessableEntity);
        var saved = (await (await parent.PutAsJsonAsync(url, new { time, steps, enabled = true, lockUntilMorning = true, cherries = 3 })).Content.ReadFromJsonAsync<BedtimeBody>())!;
        saved.Routine!.Steps.Select(s => s.Title).Should().Equal("Pijamalarını giy", "Dişlerini fırçala", "Yatağına gir");

        var tonight = (await kid.GetFromJsonAsync<ChildBedtimeBody>("/api/v1/child/bedtime"))!;
        tonight.Open.Should().BeTrue();
        tonight.Done.Should().Be(0);
        (await kid.GetFromJsonAsync<ChildHomeBedtimeBody>("/api/v1/child/home"))!.Bedtime!.Open.Should().BeTrue();

        (await kid.PostAsync("/api/v1/child/bedtime/steps/1/done", null)).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity, "steps go in order");
        await kid.PostAsync("/api/v1/child/bedtime/steps/0/done", null);
        await kid.PostAsync("/api/v1/child/bedtime/steps/0/done", null); // a double tap changes nothing
        tonight = (await (await kid.PostAsync("/api/v1/child/bedtime/steps/1/done", null)).Content.ReadFromJsonAsync<ChildBedtimeBody>())!;
        tonight.Done.Should().Be(2);
        tonight.FinishedAt.Should().BeNull();
        (await parent.GetFromJsonAsync<BedtimeBody>(url))!.Tonight!.Done.Should().Be(2);
        (await kid.GetFromJsonAsync<ChildScreenNightBody>("/api/v1/child/screen"))!.Locked.Should().BeFalse();

        tonight = (await (await kid.PostAsync("/api/v1/child/bedtime/steps/2/done", null)).Content.ReadFromJsonAsync<ChildBedtimeBody>())!;
        tonight.FinishedAt.Should().NotBeNull();
        await kid.PostAsync("/api/v1/child/bedtime/steps/2/done", null);

        // Cherries once, one "yatağında" per parent, and the phone sleeps until the morning.
        (await kid.GetFromJsonAsync<ChildHomeBody>("/api/v1/child/home"))!.Balance.Should().Be(3);
        using (var scope = api.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<HallyDbContext>();
            var notes = await db.Notifications.Where(n => n.FamilyId == family.Id && n.Kind == NotificationKind.BedtimeDone).ToListAsync();
            notes.Should().ContainSingle().Which.Title.Should().Be("🌙 Ela yatağında");
        }

        var screen = (await kid.GetFromJsonAsync<ChildScreenNightBody>("/api/v1/child/screen"))!;
        screen.Should().Be(new ChildScreenNightBody(true, true));

        // Without the night lock the phone stays open.
        await parent.PutAsJsonAsync(url, new { time, steps, enabled = true, lockUntilMorning = false, cherries = 3 });
        (await kid.GetFromJsonAsync<ChildScreenNightBody>("/api/v1/child/screen"))!.Locked.Should().BeFalse();

        // Another family's parent cannot read it.
        var stranger = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Mehmet");
        (await stranger.GetAsync(url)).StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }

    [Fact]
    public void Evenings_run_past_midnight_and_close_in_the_morning()
    {
        var routine = new BedtimeRoutine(Guid.NewGuid(), Guid.NewGuid(), DateTimeOffset.UtcNow);
        routine.Update(new TimeOnly(20, 30), [new BedtimeStep("Yatağına gir", "🛏️")], true, true, 3);
        DateTimeOffset At(int day, int h, int m) => new(2026, 11, day, h, m, 0, TimeSpan.FromHours(3));

        BedtimeRoutine.EveningOf(At(25, 21, 0)).Should().Be(new DateOnly(2026, 11, 25));
        BedtimeRoutine.EveningOf(At(26, 1, 30)).Should().Be(new DateOnly(2026, 11, 25));
        routine.IsOpen(At(25, 19, 59)).Should().BeFalse();
        routine.IsOpen(At(25, 20, 0)).Should().BeTrue("it opens half an hour early");
        routine.IsOpen(At(26, 1, 0)).Should().BeTrue();
        routine.IsOpen(At(26, 7, 0)).Should().BeFalse();
        routine.IsOpen(At(26, 15, 0)).Should().BeFalse();

        routine.Update(new TimeOnly(0, 30), [new BedtimeStep("Yatağına gir", "🛏️")], true, true, 3);
        routine.IsOpen(At(25, 23, 0)).Should().BeFalse();
        routine.IsOpen(At(26, 0, 10)).Should().BeTrue();

        var run = new BedtimeRun(Guid.NewGuid(), Guid.NewGuid(), new DateOnly(2026, 11, 25), DateTimeOffset.UtcNow);
        run.Invoking(r => r.Check(1, 2, DateTimeOffset.UtcNow)).Should().Throw<DomainException>();
        run.Check(0, 2, DateTimeOffset.UtcNow).Should().BeFalse();
        run.Check(1, 2, DateTimeOffset.UtcNow).Should().BeTrue();
        run.Check(1, 2, DateTimeOffset.UtcNow).Should().BeFalse();
    }
}

public record ChildHomeBedtimeBody(ChildBedtimeBody? Bedtime);
