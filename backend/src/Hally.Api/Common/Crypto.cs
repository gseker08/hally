using System.Security.Cryptography;
using System.Text;

namespace Hally.Api.Common;

public static class Crypto
{
    public static string NewToken(int bytes = 32) =>
        Convert.ToBase64String(RandomNumberGenerator.GetBytes(bytes)).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    public static string Sha256(string value) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value))).ToLowerInvariant();

    private const int PinIterations = 100_000;

    /// <summary>A salted PBKDF2 hash of a short PIN: <c>v1.{salt}.{hash}</c>.</summary>
    public static string HashPin(string pin)
    {
        var salt = RandomNumberGenerator.GetBytes(16);
        var hash = Rfc2898DeriveBytes.Pbkdf2(pin, salt, PinIterations, HashAlgorithmName.SHA256, 32);
        return $"v1.{Convert.ToBase64String(salt)}.{Convert.ToBase64String(hash)}";
    }

    public static bool VerifyPin(string pin, string stored)
    {
        var parts = stored.Split('.');
        if (parts is not ["v1", var salt, var hash])
        {
            return false;
        }

        var actual = Rfc2898DeriveBytes.Pbkdf2(pin, Convert.FromBase64String(salt), PinIterations, HashAlgorithmName.SHA256, 32);
        return CryptographicOperations.FixedTimeEquals(actual, Convert.FromBase64String(hash));
    }
}
