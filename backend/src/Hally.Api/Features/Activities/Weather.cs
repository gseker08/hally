using System.Globalization;
using System.Text.Json.Serialization;
using Microsoft.Extensions.Caching.Memory;

namespace Hally.Api.Features.Activities;

/// <param name="Sky">Clear, Cloudy, Rain, Snow or Storm.</param>
public record WeatherNow(int TemperatureC, string Sky, bool IsDay)
{
    /// <summary>Good enough to send a child outside: dry, daylight and not too cold or hot.</summary>
    public bool GoodForOutside => IsDay && Sky is "Clear" or "Cloudy" && TemperatureC is >= 5 and <= 33;

    /// <summary>WMO weather codes as Open-Meteo returns them.</summary>
    public static string SkyOf(int code) => code switch
    {
        0 or 1 => "Clear",
        2 or 3 or 45 or 48 => "Cloudy",
        (>= 71 and <= 77) or 85 or 86 => "Snow",
        >= 95 => "Storm",
        _ => "Rain",
    };
}

public record WeatherPlaceDto(string Name, string? Region, string? Country, double Latitude, double Longitude);

/// <summary>Current weather for a city, and the city search for the family setting. Failures return null/empty: the
/// ideas then simply mix indoors and outdoors.</summary>
public interface IWeatherService
{
    Task<WeatherNow?> CurrentAsync(double latitude, double longitude, CancellationToken ct);

    Task<IReadOnlyList<WeatherPlaceDto>> SearchAsync(string query, string language, CancellationToken ct);
}

/// <summary>Open-Meteo (free, no key). Only the city's rounded coordinates leave the server; answers are cached for
/// half an hour per city.</summary>
public sealed class OpenMeteoWeather(HttpClient http, IMemoryCache cache, ILogger<OpenMeteoWeather> logger) : IWeatherService
{
    private static readonly TimeSpan CacheFor = TimeSpan.FromMinutes(30);

    public async Task<WeatherNow?> CurrentAsync(double latitude, double longitude, CancellationToken ct)
    {
        var key = $"weather:{latitude:F1}:{longitude:F1}";
        if (cache.TryGetValue(key, out WeatherNow? hit))
        {
            return hit;
        }

        try
        {
            var url = string.Create(CultureInfo.InvariantCulture,
                $"https://api.open-meteo.com/v1/forecast?latitude={latitude:F1}&longitude={longitude:F1}&current=temperature_2m,weather_code,is_day");
            var body = await http.GetFromJsonAsync<ForecastBody>(url, ct);
            if (body?.Current is not { } c)
            {
                return null;
            }

            var now = new WeatherNow((int)Math.Round(c.Temperature), WeatherNow.SkyOf(c.Code), c.IsDay == 1);
            cache.Set(key, now, CacheFor);
            return now;
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or System.Text.Json.JsonException)
        {
            logger.LogWarning(e, "Weather lookup failed");
            return null;
        }
    }

    public async Task<IReadOnlyList<WeatherPlaceDto>> SearchAsync(string query, string language, CancellationToken ct)
    {
        try
        {
            var url = $"https://geocoding-api.open-meteo.com/v1/search?count=6&format=json&language={Uri.EscapeDataString(language)}&name={Uri.EscapeDataString(query)}";
            var body = await http.GetFromJsonAsync<SearchBody>(url, ct);
            return body?.Results?.Select(r => new WeatherPlaceDto(r.Name, r.Admin1, r.Country, Math.Round(r.Latitude, 1), Math.Round(r.Longitude, 1))).ToList() ?? [];
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or System.Text.Json.JsonException)
        {
            logger.LogWarning(e, "City search failed");
            return [];
        }
    }

    private sealed record ForecastBody([property: JsonPropertyName("current")] CurrentBody? Current);

    private sealed record CurrentBody(
        [property: JsonPropertyName("temperature_2m")] double Temperature,
        [property: JsonPropertyName("weather_code")] int Code,
        [property: JsonPropertyName("is_day")] int IsDay);

    private sealed record SearchBody([property: JsonPropertyName("results")] List<PlaceBody>? Results);

    private sealed record PlaceBody(
        [property: JsonPropertyName("name")] string Name,
        [property: JsonPropertyName("admin1")] string? Admin1,
        [property: JsonPropertyName("country")] string? Country,
        [property: JsonPropertyName("latitude")] double Latitude,
        [property: JsonPropertyName("longitude")] double Longitude);
}
