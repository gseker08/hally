using System.Text.Json;
using FluentAssertions;
using Hally.Api.Features.Notifications;

namespace Hally.Api.Tests;

public class FcmMessageTests
{
    private static JsonElement Build(bool appDraws) => JsonSerializer.SerializeToElement(FcmPushSender.BuildMessage("tok",
        new PushMessage("Ela: Ateş şurubu zamanı", "Son doz: 14:05", new Dictionary<string, string> { ["kind"] = "MedicationDue" }, appDraws)));

    [Fact]
    public void A_normal_push_carries_a_notification_for_every_platform()
    {
        var m = Build(appDraws: false);
        m.GetProperty("notification").GetProperty("title").GetString().Should().Be("Ela: Ateş şurubu zamanı");
        m.GetProperty("data").GetProperty("kind").GetString().Should().Be("MedicationDue");
        m.TryGetProperty("apns", out _).Should().BeFalse();
    }

    [Fact]
    public void An_app_drawn_push_is_data_only_on_Android_and_an_alert_on_iOS()
    {
        var m = Build(appDraws: true);
        m.TryGetProperty("notification", out _).Should().BeFalse("Android would draw it itself, without the app's buttons");
        m.GetProperty("data").GetProperty("title").GetString().Should().Be("Ela: Ateş şurubu zamanı");
        m.GetProperty("data").GetProperty("body").GetString().Should().Be("Son doz: 14:05");
        m.GetProperty("android").GetProperty("priority").GetString().Should().Be("HIGH");
        m.GetProperty("apns").GetProperty("payload").GetProperty("aps").GetProperty("alert").GetProperty("body").GetString().Should().Be("Son doz: 14:05");
    }

    [Fact]
    public void Medication_pushes_carry_the_Verdim_category_and_replace_each_other_on_iOS()
    {
        static JsonElement Med(string kind, bool appDraws) => JsonSerializer.SerializeToElement(FcmPushSender.BuildMessage("tok",
            new PushMessage("t", "b", new Dictionary<string, string> { ["kind"] = kind, ["familyId"] = "f", ["medicationId"] = "m1" }, appDraws)));

        var due = Med("MedicationDue", appDraws: true).GetProperty("apns");
        due.GetProperty("headers").GetProperty("apns-collapse-id").GetString().Should().Be("med-m1");
        due.GetProperty("payload").GetProperty("aps").GetProperty("category").GetString().Should().Be(FcmPushSender.MedicationCategory);

        var given = Med("MedicationGiven", appDraws: false).GetProperty("apns");
        given.GetProperty("headers").GetProperty("apns-collapse-id").GetString().Should().Be("med-m1");
        given.GetProperty("payload").GetProperty("aps").TryGetProperty("category", out _).Should().BeFalse();
    }

    [Fact]
    public void Child_requests_carry_Evet_Hayir_and_the_answer_replaces_them_on_iOS()
    {
        static JsonElement Ask(string kind, bool appDraws) => JsonSerializer.SerializeToElement(FcmPushSender.BuildMessage("tok",
            new PushMessage("t", "b", new Dictionary<string, string> { ["kind"] = kind, ["familyId"] = "f", ["askId"] = "a1" }, appDraws)));

        var ask = Ask("ChildAsk", appDraws: true);
        ask.TryGetProperty("notification", out _).Should().BeFalse("the app draws it with Evet/Hayır on Android");
        ask.GetProperty("data").GetProperty("title").GetString().Should().Be("t");
        ask.GetProperty("apns").GetProperty("headers").GetProperty("apns-collapse-id").GetString().Should().Be("ask-a1");
        ask.GetProperty("apns").GetProperty("payload").GetProperty("aps").GetProperty("category").GetString().Should().Be(FcmPushSender.AskCategory);

        var answered = Ask("ChildAskAnswered", appDraws: false).GetProperty("apns");
        answered.GetProperty("headers").GetProperty("apns-collapse-id").GetString().Should().Be("ask-a1");
        answered.GetProperty("payload").GetProperty("aps").TryGetProperty("category", out _).Should().BeFalse();
    }
}
