using FluentValidation;
using Hally.Api.Auth;
using Hally.Api.Common;
using Hally.Api.Features.Messages;
using Hally.Domain.Common;
using Hally.Domain.Families;
using Hally.Infrastructure.Analytics;
using Hally.Infrastructure.Persistence;
using Hally.Infrastructure.Storage;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.Families;

public record CreateFamilyRequest(string Name, string? TimeZoneId);
/// <param name="Color">One of <see cref="ChildColors.All"/>; when omitted a colour no sibling uses is picked.</param>
public record AddChildRequest(string FirstName, int? BirthYear, string? Color = null);
public record UpdateChildRequest(string FirstName, int? BirthYear, string Color);
public record MemberDto(Guid UserId, string DisplayName, string Role);
/// <param name="PhotoUrl">Relative URL of the profile photo (it changes when the photo does), or null for none.</param>
public record ChildDto(Guid Id, string FirstName, int? BirthYear, string Color, string? PhotoUrl = null)
{
    public static ChildDto From(Child c) => new(c.Id, c.FirstName, c.BirthYear, c.Color,
        c.PhotoUpdatedAt is { } at ? $"/api/v1/families/{c.FamilyId}/children/{c.Id}/photo?v={at.ToUnixTimeMilliseconds()}" : null);
}
public record FamilyDto(Guid Id, string Name, string TimeZoneId, IReadOnlyList<MemberDto> Members, IReadOnlyList<ChildDto> Children);

public class CreateFamilyRequestValidator : AbstractValidator<CreateFamilyRequest>
{
    public CreateFamilyRequestValidator()
    {
        RuleFor(x => x.Name).NotEmpty().MaximumLength(80);
        RuleFor(x => x.TimeZoneId).Must(tz => tz is null || FamilyTimeZone.IsValid(tz))
            .WithMessage("TimeZoneId must be a valid IANA time zone, e.g. Europe/Istanbul.");
    }
}

public class AddChildRequestValidator : AbstractValidator<AddChildRequest>
{
    public AddChildRequestValidator()
    {
        RuleFor(x => x.FirstName).NotEmpty().MaximumLength(40);
        RuleFor(x => x.BirthYear).InclusiveBetween(DateTime.UtcNow.Year - 25, DateTime.UtcNow.Year).When(x => x.BirthYear.HasValue);
        RuleFor(x => x.Color).Must(ChildColors.IsValid).When(x => x.Color is not null)
            .WithMessage($"Color must be one of: {string.Join(", ", ChildColors.All)}.");
    }
}

public class UpdateChildRequestValidator : AbstractValidator<UpdateChildRequest>
{
    public UpdateChildRequestValidator()
    {
        RuleFor(x => x.FirstName).NotEmpty().MaximumLength(40);
        RuleFor(x => x.BirthYear).InclusiveBetween(DateTime.UtcNow.Year - 25, DateTime.UtcNow.Year).When(x => x.BirthYear.HasValue);
        RuleFor(x => x.Color).Must(ChildColors.IsValid).WithMessage($"Color must be one of: {string.Join(", ", ChildColors.All)}.");
    }
}

[ApiController]
[Authorize]
[Route("api/v1/families")]
public class FamiliesController(HallyDbContext db, IAnalytics analytics, IDocumentStore store, TimeProvider clock, ILogger<FamiliesController> logger)
    : ControllerBase
{
    /// <summary>The app sends a small square crop; this leaves room for a full-size photo from older apps.</summary>
    public const long MaxChildPhotoBytes = 5 * 1024 * 1024;

    [HttpPost]
    [Idempotent]
    [ProducesResponseType<FamilyDto>(201)]
    public async Task<IActionResult> Create(CreateFamilyRequest request, CancellationToken ct)
    {
        var userId = User.UserId();
        var family = new Family(request.Name, request.TimeZoneId ?? FamilyTimeZone.Default, userId);
        db.Families.Add(family);
        analytics.Track(AnalyticsEvents.FamilyCreated, userId, family.Id,
            new Dictionary<string, object?> { ["time_zone"] = family.TimeZoneId });
        await db.SaveChangesAsync(ct);

        var dto = await LoadDto(family.Id, ct);
        return CreatedAtAction(nameof(Get), new { familyId = family.Id }, dto);
    }

    [HttpGet("{familyId:guid}")]
    [Authorize(Policy = Policies.FamilyMember)]
    public async Task<ActionResult<FamilyDto>> Get(Guid familyId, CancellationToken ct) => await LoadDto(familyId, ct);

    [HttpGet("{familyId:guid}/members")]
    [Authorize(Policy = Policies.FamilyMember)]
    public async Task<ActionResult<IReadOnlyList<MemberDto>>> Members(Guid familyId, CancellationToken ct) =>
        Ok((await LoadDto(familyId, ct)).Members);

    [HttpPost("{familyId:guid}/children")]
    [Idempotent]
    [Authorize(Policy = Policies.FamilyMember)]
    [ProducesResponseType<ChildDto>(201)]
    public async Task<IActionResult> AddChild(Guid familyId, AddChildRequest request, CancellationToken ct)
    {
        var family = await db.Families.Include(f => f.Children).FirstAsync(f => f.Id == familyId, ct);
        var child = family.AddChild(request.FirstName, request.BirthYear, request.Color);
        analytics.Track(AnalyticsEvents.ChildAdded, User.UserId(), familyId);
        await db.SaveChangesAsync(ct);
        return StatusCode(201, ChildDto.From(child));
    }

    [HttpPut("{familyId:guid}/children/{childId:guid}")]
    [Authorize(Policy = Policies.FamilyMember)]
    public async Task<ActionResult<ChildDto>> UpdateChild(Guid familyId, Guid childId, UpdateChildRequest request, CancellationToken ct)
    {
        var child = await db.Children.FirstOrDefaultAsync(c => c.FamilyId == familyId && c.Id == childId, ct)
                    ?? throw new NotFoundException("child.not_found", "Child not found.");
        child.Update(request.FirstName, request.BirthYear, request.Color);
        await db.SaveChangesAsync(ct);
        return ChildDto.From(child);
    }

    /// <summary>Removes a child profile and untags it from every task and event (the items themselves stay).</summary>
    [HttpDelete("{familyId:guid}/children/{childId:guid}")]
    [Authorize(Policy = Policies.FamilyMember)]
    public async Task<IActionResult> DeleteChild(Guid familyId, Guid childId, CancellationToken ct)
    {
        var child = await db.Children.FirstOrDefaultAsync(c => c.FamilyId == familyId && c.Id == childId, ct)
                    ?? throw new NotFoundException("child.not_found", "Child not found.");
        await using var tx = await db.Database.BeginTransactionAsync(ct);
        await db.Database.ExecuteSqlInterpolatedAsync(
            $"UPDATE tasks SET child_ids = array_remove(child_ids, {childId}) WHERE family_id = {familyId} AND {childId} = ANY(child_ids)", ct);
        await db.Database.ExecuteSqlInterpolatedAsync(
            $"UPDATE events SET child_ids = array_remove(child_ids, {childId}) WHERE family_id = {familyId} AND {childId} = ANY(child_ids)", ct);
        var photoKey = child.PhotoKey;
        db.Children.Remove(child);
        await db.SaveChangesAsync(ct);
        await tx.CommitAsync(ct);
        await DeleteFileAsync(photoKey);
        return NoContent();
    }

    /// <summary>Sets or replaces the child's profile photo (JPEG, PNG, WebP or HEIC, up to 5 MB). Stored encrypted like chat photos.</summary>
    [HttpPut("{familyId:guid}/children/{childId:guid}/photo")]
    [Authorize(Policy = Policies.FamilyMember)]
    [RequestSizeLimit(MaxChildPhotoBytes + 64 * 1024)]
    public async Task<ActionResult<ChildDto>> SetChildPhoto(Guid familyId, Guid childId, IFormFile? file, CancellationToken ct)
    {
        var child = await db.Children.FirstOrDefaultAsync(c => c.FamilyId == familyId && c.Id == childId, ct)
                    ?? throw new NotFoundException("child.not_found", "Child not found.");
        if (file is null || file.Length == 0 || file.Length > MaxChildPhotoBytes)
        {
            throw new DomainException("child.photo_invalid", "Send a JPEG, PNG, WebP or HEIC photo up to 5 MB.");
        }

        using var ms = new MemoryStream();
        await file.CopyToAsync(ms, ct);
        var bytes = ms.ToArray();
        // Trust the bytes, not the declared type: the photo is served back with this content type.
        var contentType = PhotoFormat.Detect(bytes)
                          ?? throw new DomainException("child.photo_invalid", "Send a JPEG, PNG, WebP or HEIC photo up to 5 MB.");

        var key = await store.SaveAsync(familyId, bytes, ct);
        string? old;
        try
        {
            old = child.SetPhoto(key, contentType, clock.GetUtcNow());
            await db.SaveChangesAsync(ct);
        }
        catch
        {
            await store.DeleteAsync(key, CancellationToken.None);
            throw;
        }

        await DeleteFileAsync(old);
        return ChildDto.From(child);
    }

    /// <summary>The child's profile photo, decrypted. Only members of the family can read it.</summary>
    [HttpGet("{familyId:guid}/children/{childId:guid}/photo")]
    [Authorize(Policy = Policies.FamilyMember)]
    public async Task<IActionResult> ChildPhoto(Guid familyId, Guid childId, CancellationToken ct)
    {
        var child = await db.Children.AsNoTracking().FirstOrDefaultAsync(c => c.FamilyId == familyId && c.Id == childId, ct);
        if (child?.PhotoKey is null || await store.ReadAsync(child.PhotoKey, ct) is not { } bytes)
        {
            throw new NotFoundException("child.photo_not_found", "Photo not found.");
        }

        // The URL carries the photo's version, so a cached copy never goes stale.
        Response.Headers.CacheControl = "private, max-age=31536000, immutable";
        Response.Headers.XContentTypeOptions = "nosniff";
        return File(bytes, child.PhotoContentType ?? "image/jpeg");
    }

    /// <summary>Removes the child's profile photo; the app shows the initial again.</summary>
    [HttpDelete("{familyId:guid}/children/{childId:guid}/photo")]
    [Authorize(Policy = Policies.FamilyMember)]
    public async Task<ActionResult<ChildDto>> DeleteChildPhoto(Guid familyId, Guid childId, CancellationToken ct)
    {
        var child = await db.Children.FirstOrDefaultAsync(c => c.FamilyId == familyId && c.Id == childId, ct)
                    ?? throw new NotFoundException("child.not_found", "Child not found.");
        var old = child.RemovePhoto();
        await db.SaveChangesAsync(ct);
        await DeleteFileAsync(old);
        return ChildDto.From(child);
    }

    private async Task DeleteFileAsync(string? key)
    {
        if (key is null)
        {
            return;
        }

        try
        {
            await store.DeleteAsync(key, CancellationToken.None);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // The row no longer points at it. Log it so an operator can remove the leftover encrypted file.
            logger.LogWarning(ex, "Could not delete a replaced child photo");
        }
    }

    private async Task<FamilyDto> LoadDto(Guid familyId, CancellationToken ct)
    {
        var family = await db.Families.AsNoTracking().Include(f => f.Children)
                         .FirstOrDefaultAsync(f => f.Id == familyId, ct)
                     ?? throw new NotFoundException("family.not_found", "Family not found.");
        var members = await db.FamilyMembers.AsNoTracking()
            .Where(m => m.FamilyId == familyId)
            .Join(db.Users, m => m.UserId, u => u.Id, (m, u) => new { m.UserId, u.DisplayName, m.Role, m.CreatedAt })
            .OrderBy(m => m.CreatedAt)
            .ToListAsync(ct);

        return new FamilyDto(family.Id, family.Name, family.TimeZoneId,
            members.Select(m => new MemberDto(m.UserId, m.DisplayName, m.Role.ToString())).ToList(),
            family.Children.OrderBy(c => c.CreatedAt).Select(ChildDto.From).ToList());
    }
}
