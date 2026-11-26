using Hally.Api.Auth;
using Hally.Api.Common;
using Hally.Api.Features.ChildMode;
using Hally.Domain.Activities;
using Hally.Domain.ChildMode;
using Hally.Domain.Common;
using Hally.Domain.Users;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.Activities;

/// <param name="Place">Indoor or Outdoor.</param>
/// <param name="Own">The family's own idea (a parent added it).</param>
/// <param name="State">Todo, Pending (waits for a parent) or Done, for today.</param>
public record ActivityIdeaDto(Guid Id, string Emoji, string Title, string? Hint, string Place, int? Minutes, int Cherries, bool Own, string State);

/// <param name="Weather">Null when the family set no city or the lookup failed.</param>
/// <param name="Age">From the child's birth year; null when unknown (then every idea is shown).</param>
/// <param name="DoneToday">Ideas marked done today (waiting or approved); at most <paramref name="DailyLimit"/>.</param>
public record ChildActivitiesDto(WeatherNow? Weather, string? WeatherPlace, int? Age, int DoneToday, int DailyLimit, IReadOnlyList<ActivityIdeaDto> Ideas);

public record OwnActivityDto(Guid Id, string Emoji, string Title, string Place, int Cherries);

public record OwnActivityRequest(string Title, string Emoji, int Cherries, string Place);

/// <summary>The city for the weather; a null or empty <c>Name</c> clears it.</summary>
public record WeatherPlaceRequest(string? Name, double? Latitude, double? Longitude);

public record FamilyActivitiesDto(WeatherPlaceDto? Place, IReadOnlyList<OwnActivityDto> Own, int BuiltIn);

/// <summary>
/// "Şimdi ne yapsam?" on the child's phone: screen-free ideas by age and the weather where the family lives. "Yaptım"
/// goes through the same parent approval as chores, and the cherries land in the child's jar.
/// </summary>
[ApiController]
[Authorize(Policy = ChildDeviceAuth.Policy)]
[Route("api/v1/child/activities")]
public class ChildActivitiesController(HallyDbContext db, ChildModeService childMode, IWeatherService weather, TimeProvider clock) : ControllerBase
{
    /// <param name="lang">tr (default) or en: the language of the built-in ideas.</param>
    [HttpGet]
    public async Task<ChildActivitiesDto> Get([FromQuery] string? lang, CancellationToken ct)
    {
        var (familyId, childId) = (User.ChildFamilyId(), User.ChildId());
        var turkish = Locales.IsTurkish(lang);
        var family = await db.Families.AsNoTracking().FirstAsync(f => f.Id == familyId, ct);
        var child = await db.Children.AsNoTracking().FirstAsync(c => c.Id == childId, ct);
        var today = FamilyTimeZone.LocalDate(clock.GetUtcNow(), family.TimeZoneId);
        int? age = child.BirthYear is { } y ? Math.Max(0, today.Year - y) : null;

        WeatherNow? now = null;
        if (family.WeatherLatitude is { } lat && family.WeatherLongitude is { } lon)
        {
            now = await weather.CurrentAsync(lat, lon, ct);
        }

        var claims = await db.ChildClaims.AsNoTracking()
            .Where(c => c.ChildId == childId && c.Kind == ClaimKind.Activity && c.Day == today && c.Status != ClaimStatus.Rejected)
            .Select(c => new { c.ItemId, c.Status }).ToListAsync(ct);
        string State(Guid id) => claims.FirstOrDefault(c => c.ItemId == id)?.Status switch
        {
            ClaimStatus.Approved => "Done",
            ClaimStatus.Pending => "Pending",
            _ => "Todo",
        };

        var own = await db.FamilyActivities.AsNoTracking().Where(a => a.FamilyId == familyId).OrderBy(a => a.CreatedAt).ToListAsync(ct);
        var ideas = own.Select(a => (Idea: new ActivityIdeaDto(a.Id, a.Emoji, a.Title, null, a.Place.ToString(), null, a.Cherries, true, State(a.Id)), a.Place))
            .Concat(Shuffle(ActivityCatalog.All.Where(a => a.Suits(age)), childId, today)
                .Select(a => (Idea: new ActivityIdeaDto(a.Id, a.Emoji, a.Title(turkish), a.Hint(turkish), a.Place.ToString(), a.Minutes, a.Cherries, false, State(a.Id)), a.Place)))
            .ToList();

        // Rain, cold or dark: indoor ideas only. Nice weather: outdoor ideas first.
        if (now is { GoodForOutside: false })
        {
            ideas = ideas.Where(i => i.Place == ActivityPlace.Indoor || i.Idea.State != "Todo").ToList();
        }
        else if (now is { GoodForOutside: true })
        {
            ideas = ideas.OrderBy(i => i.Place == ActivityPlace.Outdoor ? 0 : 1).ToList();
        }

        return new ChildActivitiesDto(now, family.WeatherPlace, age, claims.Count, ActivityCatalog.DailyLimit, ideas.Select(i => i.Idea).ToList());
    }

    /// <summary>"Yaptım": waits for a parent (or lands at once with approval off). 422 <c>activity.daily_limit</c> after
    /// <see cref="ActivityCatalog.DailyLimit"/> ideas in a day.</summary>
    [HttpPost("{activityId:guid}/done")]
    public async Task<ChildActivitiesDto> Done(Guid activityId, [FromQuery] string? lang, CancellationToken ct)
    {
        var turkish = Locales.IsTurkish(lang);
        await childMode.MarkDoneAsync(User.ChildFamilyId(), User.ChildId(), ClaimKind.Activity, activityId, ct, turkish);
        return await Get(lang, ct);
    }

    /// <summary>The same order all day for one child, a new one tomorrow.</summary>
    private static IEnumerable<CatalogActivity> Shuffle(IEnumerable<CatalogActivity> ideas, Guid childId, DateOnly day)
    {
        var random = new Random(childId.GetHashCode() ^ day.DayNumber);
        return ideas.Select(a => (a, k: random.Next())).OrderBy(x => x.k).Select(x => x.a).ToList();
    }
}

/// <summary>The parents' side: the city for the weather and the family's own ideas. Caregivers cannot change them.</summary>
[ApiController]
[Authorize(Policy = Policies.FamilyMember)]
[Route("api/v1/families/{familyId:guid}")]
public class FamilyActivitiesController(HallyDbContext db, TimeProvider clock) : ControllerBase
{
    [HttpGet("activities")]
    public async Task<FamilyActivitiesDto> Get(Guid familyId, CancellationToken ct)
    {
        var family = await db.Families.AsNoTracking().FirstAsync(f => f.Id == familyId, ct);
        var own = await db.FamilyActivities.AsNoTracking().Where(a => a.FamilyId == familyId).OrderBy(a => a.CreatedAt)
            .Select(a => new OwnActivityDto(a.Id, a.Emoji, a.Title, a.Place.ToString(), a.Cherries)).ToListAsync(ct);
        return new FamilyActivitiesDto(PlaceOf(family), own, ActivityCatalog.All.Count);
    }

    [HttpPost("activities")]
    public async Task<OwnActivityDto> Add(Guid familyId, OwnActivityRequest request, CancellationToken ct)
    {
        if (!Enum.TryParse<ActivityPlace>(request.Place, true, out var place) || !Enum.IsDefined(place))
        {
            throw new DomainException("activity.place_invalid", "Place must be Indoor or Outdoor.");
        }

        if (await db.FamilyActivities.CountAsync(a => a.FamilyId == familyId, ct) >= FamilyActivity.MaxPerFamily)
        {
            throw new DomainException("activity.too_many", $"At most {FamilyActivity.MaxPerFamily} ideas.");
        }

        var idea = new FamilyActivity(familyId, request.Title, request.Emoji, request.Cherries, place, User.UserId(), clock.GetUtcNow());
        db.FamilyActivities.Add(idea);
        await db.SaveChangesAsync(ct);
        return new OwnActivityDto(idea.Id, idea.Emoji, idea.Title, idea.Place.ToString(), idea.Cherries);
    }

    [HttpDelete("activities/{activityId:guid}")]
    public async Task<IActionResult> Delete(Guid familyId, Guid activityId, CancellationToken ct)
    {
        var deleted = await db.FamilyActivities.Where(a => a.Id == activityId && a.FamilyId == familyId).ExecuteDeleteAsync(ct);
        return deleted == 0 ? throw new NotFoundException("activity.not_found", "Idea not found.") : NoContent();
    }

    [HttpPut("weather-place")]
    public async Task<FamilyActivitiesDto> SetPlace(Guid familyId, WeatherPlaceRequest request, CancellationToken ct)
    {
        var family = await db.Families.FirstAsync(f => f.Id == familyId, ct);
        family.SetWeatherPlace(request.Name, request.Latitude, request.Longitude);
        await db.SaveChangesAsync(ct);
        return await Get(familyId, ct);
    }

    private static WeatherPlaceDto? PlaceOf(Domain.Families.Family f) =>
        f is { WeatherPlace: { } name, WeatherLatitude: { } lat, WeatherLongitude: { } lon } ? new WeatherPlaceDto(name, null, null, lat, lon) : null;
}

/// <summary>City search for the weather setting (Open-Meteo's list of places).</summary>
[ApiController]
[Authorize]
[Route("api/v1/weather")]
public class WeatherController(IWeatherService weather) : ControllerBase
{
    [HttpGet("places")]
    public async Task<IReadOnlyList<WeatherPlaceDto>> Places([FromQuery] string? q, [FromQuery] string? lang, CancellationToken ct) =>
        q is null || q.Trim().Length < 2 || q.Length > 60 ? [] : await weather.SearchAsync(q.Trim(), lang is { Length: 2 } ? lang : "tr", ct);
}
