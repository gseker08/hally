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
}
