using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using Google.Apis.Auth.OAuth2;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Hally.Api.Features.Notifications;

public class PushOptions
{
    public const string Section = "Push";

    /// <summary>Firebase project id. Empty = pushes are only logged (development, tests, before Firebase is set up).</summary>
    public string FcmProjectId { get; set; } = string.Empty;

    /// <summary>Service account JSON (secret: set via environment, never commit).</summary>
    public string FcmServiceAccountJson { get; set; } = string.Empty;
}

/// <param name="AppDrawsOnAndroid">Sent to Android as data only (title and body in <c>data</c>), so the app draws the
/// notification itself, with buttons such as "Verdim". iOS still gets a normal alert.</param>
public record PushMessage(string Title, string Body, IReadOnlyDictionary<string, string> Data, bool AppDrawsOnAndroid = false);

public interface IPushSender
{
    /// <summary>Sends to each token and returns the tokens the provider reported as no longer valid.</summary>
    Task<IReadOnlyList<string>> SendAsync(IReadOnlyList<string> tokens, PushMessage message, CancellationToken ct);
}

/// <summary>Used until Firebase is configured. Logs that a push would be sent, never the content (it may name children).</summary>
public class LoggingPushSender(ILogger<LoggingPushSender> logger) : IPushSender
{
    public Task<IReadOnlyList<string>> SendAsync(IReadOnlyList<string> tokens, PushMessage message, CancellationToken ct)
    {
        logger.LogInformation("Push (not configured): {Count} device(s), kind {Kind}", tokens.Count, message.Data.GetValueOrDefault("kind"));
        return Task.FromResult<IReadOnlyList<string>>([]);
    }
}

/// <summary>Firebase Cloud Messaging HTTP v1 (covers Android and, through APNs, iOS).</summary>
public class FcmPushSender(HttpClient http, IOptions<PushOptions> options, ILogger<FcmPushSender> logger) : IPushSender
{
    private readonly ITokenAccess _credential = GoogleCredential.FromJson(options.Value.FcmServiceAccountJson)
        .CreateScoped("https://www.googleapis.com/auth/firebase.messaging").UnderlyingCredential;

    public async Task<IReadOnlyList<string>> SendAsync(IReadOnlyList<string> tokens, PushMessage message, CancellationToken ct)
    {
        var invalid = new List<string>();
        var accessToken = await _credential.GetAccessTokenForRequestAsync(cancellationToken: ct);
        var url = $"https://fcm.googleapis.com/v1/projects/{options.Value.FcmProjectId}/messages:send";
        foreach (var token in tokens)
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, url)
            {
                Content = JsonContent.Create(new { message = BuildMessage(token, message) }),
            };
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
            using var response = await http.SendAsync(request, ct);
            if (response.StatusCode is HttpStatusCode.NotFound or HttpStatusCode.BadRequest)
            {
                invalid.Add(token); // UNREGISTERED / INVALID_ARGUMENT: the app was removed or the token rotated
            }
            else if (!response.IsSuccessStatusCode)
            {
                logger.LogWarning("FCM send failed with {Status}", (int)response.StatusCode);
            }
        }

        return invalid;
    }

    /// <summary>The FCM HTTP v1 <c>message</c> object for one device.</summary>
    public static object BuildMessage(string token, PushMessage message)
    {
        if (!message.AppDrawsOnAndroid)
        {
            return new
            {
                token,
                notification = new { title = message.Title, body = message.Body },
                data = message.Data,
                android = new { priority = "HIGH" },
            };
        }

        var data = new Dictionary<string, string>(message.Data) { ["title"] = message.Title, ["body"] = message.Body };
        return new
        {
            token,
            data,
            android = new { priority = "HIGH" },
            apns = new { payload = new { aps = new { alert = new { title = message.Title, body = message.Body }, sound = "default" } } },
        };
    }
}
