namespace Hally.Api.Tests;

/// <summary>Tests that log minutes "today" and then move the clock forward break near the family's local midnight:
/// the minutes land on two days. The API's clock is the real time plus test offsets, and auth tokens are checked
/// against the real time, so the clock itself cannot be parked at noon. Instead such families live in a time zone where
/// it is daytime right now (some zone in this list always is).</summary>
public static class TestZones
{
    private static readonly string[] Zones =
        ["Europe/Istanbul", "America/New_York", "Asia/Tokyo", "America/Los_Angeles", "Asia/Kolkata", "Pacific/Auckland"];

    public static string Daytime(TimeProvider clock)
    {
        var now = clock.GetUtcNow();
        return Zones.First(z => TimeZoneInfo.ConvertTime(now, TimeZoneInfo.FindSystemTimeZoneById(z)).Hour is >= 6 and < 18);
    }
}
