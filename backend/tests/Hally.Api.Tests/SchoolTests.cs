using System.Net;
using System.Net.Http.Json;
using FluentAssertions;
using Hally.Api.Features.School;
using Hally.Domain.Common;
using Hally.Domain.Notifications;
using Hally.Domain.School;
using Hally.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;

namespace Hally.Api.Tests;

public record SchoolSettingsBody(List<string> BellTimes, List<string> DailyItems, string? ReminderTime, bool ChildPhone, bool QuietOnHolidays);
public record LessonBody(Guid Id, Guid ChildId, int Weekday, int Period, string Subject, List<string> Items);
public record BagItemBody(string Key, string Kind, string Text, List<string> Subjects, DateOnly? ExamDate, bool Packed);
public record BagBody(Guid ChildId, string ChildName, DateOnly Day, List<string> Subjects, List<BagItemBody> Items, DateTimeOffset? ReadyAt, bool ReadyByChild, string? ChildClaim);
public record SchoolBody(DateOnly Today, bool TodayIsSchoolDay, SchoolSettingsBody Settings, List<SchoolBreakDto> Breaks, List<LessonBody> Lessons, List<BagBody> Bags);
public record ChildLessonBody(int Period, string? Start, string Subject, List<string> Items, bool Now);
public record ChildSchoolBody(List<ChildLessonBody> Today, BagBody? Bag);
public record ChildHomeSchoolBody(int Balance, ChildSchoolBody? School);

[Collection(ApiCollection.Name)]
public class SchoolTests(HallyApiFactory api)
{
    private string EveningZone()
    {
        var offset = 20 - api.Clock.GetUtcNow().UtcDateTime.Hour;
        if (offset < -12)
        {
            offset += 24;
        }

        if (offset > 14)
        {
            offset -= 24;
        }

        return offset == 0 ? "Etc/UTC" : $"Etc/GMT{(offset > 0 ? "-" : "+")}{Math.Abs(offset)}";
    }

    private async Task<(HttpClient Parent, string F, Guid FamilyId, Guid ChildId, DateOnly Today)> FamilyAsync(string? zone = null)
    {
        zone ??= TestZones.Daytime(api.Clock);
        var parent = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Ayşe");
        var family = (await (await parent.PostIdempotentAsync("/api/v1/families", new { name = "Yılmaz", timeZoneId = zone })).Content.ReadFromJsonAsync<FamilyBody>())!;
        var child = (await (await parent.PostIdempotentAsync($"/api/v1/families/{family.Id}/children", new { firstName = "Ela" })).Content.ReadFromJsonAsync<ChildBody>())!;
        var f = $"/api/v1/families/{family.Id}";

        // Weekend-proof: holidays off, and the same lessons every weekday.
        (await parent.PutAsJsonAsync($"{f}/school/settings", new { bellTimes = new[] { "08:30", "09:20", "10:10" }, dailyItems = new[] { "🍎 Beslenme" }, reminderTime = "19:30", childPhone = true, quietOnHolidays = false }))
            .EnsureSuccessStatusCode();
        for (var day = 1; day <= 5; day++)
        {
            await parent.PutAsJsonAsync($"{f}/school/lessons", new { childId = child.Id, weekday = day, period = 1, subject = "Matematik" });
            await parent.PutAsJsonAsync($"{f}/school/lessons", new { childId = child.Id, weekday = day, period = 3, subject = "Beden Eğitimi", items = new[] { "👟 Eşofman", "💧 Su" } });
        }

        return (parent, f, family.Id, child.Id, FamilyTimeZone.LocalDate(api.Clock.GetUtcNow(), zone));
    }

    private static bool Weekday(DateOnly day) => day.DayOfWeek is not (DayOfWeek.Saturday or DayOfWeek.Sunday);

    [Fact]
    public void School_days_skip_weekends_breaks_and_official_holidays()
    {
        var plan = new SchoolPlan(Guid.NewGuid(), DateTimeOffset.UtcNow);
        var breaks = new[] { new SchoolBreak(plan.FamilyId, "Ara tatil", new DateOnly(2026, 11, 16), new DateOnly(2026, 11, 20), DateTimeOffset.UtcNow) };
        plan.IsSchoolDay(new DateOnly(2026, 11, 26), breaks).Should().BeTrue("a Thursday");
        plan.IsSchoolDay(new DateOnly(2026, 11, 28), breaks).Should().BeFalse("a Saturday");
        plan.IsSchoolDay(new DateOnly(2026, 11, 18), breaks).Should().BeFalse("the break");
        plan.IsSchoolDay(new DateOnly(2026, 10, 29), breaks).Should().BeFalse("Cumhuriyet Bayramı");
        plan.Update(DefaultsOf(plan), [], null, true, quietOnHolidays: false);
        plan.IsSchoolDay(new DateOnly(2026, 10, 29), breaks).Should().BeTrue("holidays not skipped");

        var act = () => plan.Update(["09:00", "08:30"], [], null, true, true);
        act.Should().Throw<DomainException>().Which.Code.Should().Be("school.bell_order");
    }

    private static List<string> DefaultsOf(SchoolPlan plan) => [.. plan.BellTimes];

    [Fact]
    public async Task The_timetable_builds_tomorrows_bag_and_hazirladik_packs_it()
    {
        var (parent, f, _, childId, today) = await FamilyAsync();
        var tomorrow = today.AddDays(1);
        var exam = (await (await parent.PostAsJsonAsync($"{f}/exams", new { childId, subject = "Fen", date = tomorrow }))
            .Content.ReadFromJsonAsync<ExamBody>())!;

        var school = (await parent.GetFromJsonAsync<SchoolBody>($"{f}/school"))!;
        school.Lessons.Should().HaveCount(10);
        school.Settings.Should().BeEquivalentTo(new SchoolSettingsBody(["08:30", "09:20", "10:10"], ["🍎 Beslenme"], "19:30", true, false));
        if (!Weekday(tomorrow))
        {
            school.Bags.Should().BeEmpty("no school tomorrow");
            return;
        }

        var bag = school.Bags.Single();
        bag.Subjects.Should().Equal("Matematik", "Beden Eğitimi");
        bag.Items.Select(i => (i.Key, i.Kind)).Should().Equal(("👟 Eşofman", "Item"), ("💧 Su", "Item"), ("🍎 Beslenme", "Item"), ($"exam:{exam.Id:N}", "Exam"));
        bag.Items[0].Subjects.Should().Equal("Beden Eğitimi");

        bag = (await (await parent.PutAsJsonAsync($"{f}/school/bags/{childId}/items", new { key = "💧 Su", packed = true })).Content.ReadFromJsonAsync<SchoolBody>())!.Bags.Single();
        bag.Items.Where(i => i.Packed).Select(i => i.Key).Should().Equal("💧 Su");
        bag.ReadyAt.Should().BeNull();

        // A caregiver sees the timetable, helps pack, but cannot change lessons.
        var invite = (await (await parent.PostIdempotentAsync($"{f}/invitations", new { role = "caregiver" })).Content.ReadFromJsonAsync<InvitationBody>())!;
        var nanny = await api.SignInAsync($"{Guid.NewGuid():N}@example.com", "Fatma");
        (await nanny.PostIdempotentAsync($"/api/v1/invitations/{invite.Token}/accept", null)).EnsureSuccessStatusCode();
        (await nanny.PutAsJsonAsync($"{f}/school/lessons", new { childId, weekday = 1, period = 2, subject = "Müzik" })).StatusCode.Should().Be(HttpStatusCode.Forbidden);
        bag = (await (await nanny.PostAsync($"{f}/school/bags/{childId}/ready", null)).Content.ReadFromJsonAsync<SchoolBody>())!.Bags.Single();
        bag.ReadyAt.Should().NotBeNull();
        bag.ReadyByChild.Should().BeFalse();
        bag.Items.Should().OnlyContain(i => i.Packed);

        // An empty subject clears the period.
        school = (await (await parent.PutAsJsonAsync($"{f}/school/lessons", new { childId, weekday = 1, period = 3, subject = "" })).Content.ReadFromJsonAsync<SchoolBody>())!;
        school.Lessons.Should().HaveCount(9);
        (await parent.PutAsJsonAsync($"{f}/school/lessons", new { childId, weekday = 6, period = 1, subject = "Mat" })).StatusCode.Should().Be(HttpStatusCode.BadRequest);
    }

    [Fact]
    public async Task The_child_sees_todays_lessons_and_cantam_hazir_asks_for_a_cherry()
    {
        var (parent, f, _, childId, today) = await FamilyAsync();
        var code = (await (await parent.PostAsync($"{f}/children/{childId}/pairing-code", null)).Content.ReadFromJsonAsync<PairingCodeBody>())!;
        var paired = (await (await api.CreateClient().PostAsJsonAsync("/api/v1/child/pair", new { code = code.Code })).Content.ReadFromJsonAsync<PairResultBody>())!;
        var kid = api.CreateClient();
        kid.DefaultRequestHeaders.Add("X-Hally-Child", paired.Token);

        var home = (await kid.GetFromJsonAsync<ChildHomeSchoolBody>("/api/v1/child/home"))!;
        home.School.Should().NotBeNull();
        if (Weekday(today))
        {
            home.School!.Today.Select(l => (l.Period, l.Start, l.Subject)).Should().Equal((1, "08:30", "Matematik"), (3, "10:10", "Beden Eğitimi"));
        }

        if (!Weekday(today.AddDays(1)))
        {
            home.School!.Bag.Should().BeNull();
            return;
        }

        var school = (await (await kid.PutAsJsonAsync("/api/v1/child/school/bag/items", new { key = "👟 Eşofman", packed = true })).Content.ReadFromJsonAsync<ChildSchoolBody>())!;
        school.Bag!.Items.Single(i => i.Key == "👟 Eşofman").Packed.Should().BeTrue();
        school = (await (await kid.PostAsync("/api/v1/child/school/bag/ready", null)).Content.ReadFromJsonAsync<ChildSchoolBody>())!;
        school.Bag!.ReadyByChild.Should().BeTrue();
        school.Bag.ChildClaim.Should().Be("Pending");
        await kid.PostAsync("/api/v1/child/school/bag/ready", null);

        var claim = (await parent.GetFromJsonAsync<List<ClaimBody>>($"{f}/claims"))!.Single();
        (claim.Kind, claim.Title, claim.Cherries).Should().Be(("Bag", "🎒 Çantam hazır", 1));
        await parent.PostAsync($"{f}/claims/{claim.Id}/approve", null);
        home = (await kid.GetFromJsonAsync<ChildHomeSchoolBody>("/api/v1/child/home"))!;
        home.Balance.Should().Be(1);
        home.School!.Bag!.ChildClaim.Should().Be("Done");
        (await parent.GetFromJsonAsync<SchoolBody>($"{f}/school"))!.Bags.Single().ReadyByChild.Should().BeTrue();

        // Parents can keep the list off the child's phone.
        await parent.PutAsJsonAsync($"{f}/school/settings", new { bellTimes = new[] { "08:30" }, reminderTime = "19:30", childPhone = false, quietOnHolidays = false });
        (await kid.GetFromJsonAsync<ChildHomeSchoolBody>("/api/v1/child/home"))!.School!.Bag.Should().BeNull();
        (await kid.PostAsync("/api/v1/child/school/bag/ready", null)).StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
    }

    [Fact]
    public async Task After_the_reminder_time_parents_get_one_yarin_cantaya_unless_the_bag_is_ready()
    {
        var zone = EveningZone();
        var (parent, f, familyId, childId, today) = await FamilyAsync(zone);
        using var scope = api.Services.CreateScope();
        var job = scope.ServiceProvider.GetRequiredService<SchoolService>();
        var db = scope.ServiceProvider.GetRequiredService<HallyDbContext>();
        await job.EveningAsync(default);
        var notes = await db.Notifications.Where(n => n.FamilyId == familyId).ToListAsync();
        if (!Weekday(today.AddDays(1)))
        {
            notes.Should().BeEmpty("no school tomorrow");
            return;
        }

        var note = notes.Should().ContainSingle().Subject;
        (note.Kind, note.TargetId).Should().Be((NotificationKind.SchoolBag, (Guid?)childId));
        note.Title.Should().Be("🎒 Yarın çantaya · Ela");
        note.Body.Should().Be("Beden Eğitimi: 👟 Eşofman, 💧 Su. Her gün: 🍎 Beslenme.");
        (await job.EveningAsync(default)).Should().Be(0, "once an evening");

        // A second child whose bag is already packed gets no note; a family with the reminder off neither.
        var other = (await (await parent.PostIdempotentAsync($"{f}/children", new { firstName = "Can" })).Content.ReadFromJsonAsync<ChildBody>())!;
        (await parent.PostAsync($"{f}/school/children/{other.Id}/copy-from/{childId}", null)).EnsureSuccessStatusCode();
        (await parent.PostAsync($"{f}/school/bags/{other.Id}/ready", null)).EnsureSuccessStatusCode();
        (await job.EveningAsync(default)).Should().Be(0);

        var (_, _, family2, _, _) = await FamilyAsync(zone);
        await db.SchoolPlans.Where(p => p.FamilyId == family2).ExecuteUpdateAsync(s => s.SetProperty(p => p.ReminderTime, (TimeOnly?)null));
        await job.EveningAsync(default);
        (await db.Notifications.CountAsync(n => n.FamilyId == family2)).Should().Be(0);
    }
}
