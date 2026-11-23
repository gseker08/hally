namespace Hally.Domain.Common;

/// <summary>IANA time zone helpers. Family dates are always resolved in the family's zone.</summary>
public static class FamilyTimeZone
{
    public const string Default = "Europe/Istanbul";

    public static bool IsValid(string? id)
    {
        if (string.IsNullOrWhiteSpace(id) || !id.Contains('/') && id != "UTC")
        {
            return false;
        }

        return TimeZoneInfo.TryFindSystemTimeZoneById(id, out _);
    }

    public static DateTimeOffset ToFamilyTime(DateTimeOffset utc, string timeZoneId)
    {
        var zone = TimeZoneInfo.FindSystemTimeZoneById(timeZoneId);
        return TimeZoneInfo.ConvertTime(utc, zone);
    }

    /// <summary>The family-local calendar day that <paramref name="utc"/> falls on.</summary>
    public static DateOnly LocalDate(DateTimeOffset utc, string timeZoneId) => DateOnly.FromDateTime(ToFamilyTime(utc, timeZoneId).DateTime);

    /// <summary>The instant the family-local <paramref name="day"/> begins (midnight; the first valid time on a DST gap).</summary>
    public static DateTimeOffset StartOfDay(DateOnly day, string timeZoneId)
    {
        var zone = TimeZoneInfo.FindSystemTimeZoneById(timeZoneId);
        var local = day.ToDateTime(TimeOnly.MinValue);
        while (zone.IsInvalidTime(local))
        {
            local = local.AddMinutes(30);
        }

        return new DateTimeOffset(local, zone.GetUtcOffset(local)).ToUniversalTime();
    }
}
