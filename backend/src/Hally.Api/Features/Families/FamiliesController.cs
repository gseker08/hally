using FluentValidation;
using Hally.Api.Auth;
using Hally.Api.Common;
using Hally.Domain.Common;
using Hally.Domain.Families;
using Hally.Infrastructure.Analytics;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.Families;

public record CreateFamilyRequest(string Name, string? TimeZoneId);
/// <param name="Color">One of <see cref="ChildColors.All"/>; when omitted a colour no sibling uses is picked.</param>
public record AddChildRequest(string FirstName, int? BirthYear, string? Color = null);
public record UpdateChildRequest(string FirstName, int? BirthYear, string Color);
public record MemberDto(Guid UserId, string DisplayName, string Role);
public record ChildDto(Guid Id, string FirstName, int? BirthYear, string Color)
{
    public static ChildDto From(Child c) => new(c.Id, c.FirstName, c.BirthYear, c.Color);
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
public class FamiliesController(HallyDbContext db, IAnalytics analytics) : ControllerBase
{
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
        db.Children.Remove(child);
        await db.SaveChangesAsync(ct);
        await tx.CommitAsync(ct);
        return NoContent();
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
