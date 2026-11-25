using System.Security.Claims;
using System.Text.Encodings.Web;
using Hally.Api.Common;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authentication;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace Hally.Api.Auth;

/// <summary>
/// A paired child phone signs its requests with its device token in the <c>X-Hally-Child</c> header. This is its own
/// authentication scheme: the default (JWT) scheme never reads that header, so a child phone can only reach the
/// <c>/api/v1/child</c> endpoints, never a parent's. Every request checks the token in the database, so a parent's
/// "unpair" works at once.
/// </summary>
public static class ChildDeviceAuth
{
    public const string Scheme = "child-device";
    public const string Header = "X-Hally-Child";
    public const string Policy = "child-device";

    public const string ChildIdClaim = "child_id";
    public const string FamilyIdClaim = "family_id";
    public const string DeviceIdClaim = "device_id";

    public static Guid ChildId(this ClaimsPrincipal user) => Guid.Parse(user.FindFirstValue(ChildIdClaim)!);

    public static Guid ChildFamilyId(this ClaimsPrincipal user) => Guid.Parse(user.FindFirstValue(FamilyIdClaim)!);

    public static Guid ChildDeviceId(this ClaimsPrincipal user) => Guid.Parse(user.FindFirstValue(DeviceIdClaim)!);
}

public class ChildDeviceAuthHandler(
    IOptionsMonitor<AuthenticationSchemeOptions> options,
    ILoggerFactory logger,
    UrlEncoder encoder,
    HallyDbContext db,
    TimeProvider clock) : AuthenticationHandler<AuthenticationSchemeOptions>(options, logger, encoder)
{
    protected override async Task<AuthenticateResult> HandleAuthenticateAsync()
    {
        if (!Request.Headers.TryGetValue(ChildDeviceAuth.Header, out var values) || values.ToString() is not { Length: > 0 and < 200 } token)
        {
            return AuthenticateResult.NoResult();
        }

        var hash = Crypto.Sha256(token);
        var device = await db.ChildDevices.FirstOrDefaultAsync(d => d.TokenHash == hash && d.RevokedAt == null, Context.RequestAborted);
        if (device is null)
        {
            return AuthenticateResult.Fail("Unknown or unpaired device.");
        }

        var now = clock.GetUtcNow();
        if (now - device.LastSeenAt > TimeSpan.FromMinutes(5))
        {
            device.Seen(now);
            await db.SaveChangesAsync(Context.RequestAborted);
        }

        var identity = new ClaimsIdentity(
        [
            new Claim(ChildDeviceAuth.ChildIdClaim, device.ChildId.ToString()),
            new Claim(ChildDeviceAuth.FamilyIdClaim, device.FamilyId.ToString()),
            new Claim(ChildDeviceAuth.DeviceIdClaim, device.Id.ToString()),
        ], ChildDeviceAuth.Scheme);
        return AuthenticateResult.Success(new AuthenticationTicket(new ClaimsPrincipal(identity), ChildDeviceAuth.Scheme));
    }
}
