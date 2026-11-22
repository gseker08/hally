using System.Security.Claims;

namespace Hally.Api.Common;

public static class ClaimsExtensions
{
    public static Guid UserId(this ClaimsPrincipal user) =>
        Guid.TryParse(user.FindFirstValue(ClaimTypes.NameIdentifier) ?? user.FindFirstValue("sub"), out var id)
            ? id
            : throw new AuthRequiredException();
}

/// <summary>
/// The caller's token does not identify an existing user. Mapped to 401. Deliberately not
/// <see cref="UnauthorizedAccessException"/>, which the runtime also throws for file-system permission errors.
/// </summary>
public class AuthRequiredException() : Exception("Authentication required.");
