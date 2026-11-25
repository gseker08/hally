using System.Security.Cryptography;
using FluentValidation;
using Hally.Api.Auth;
using Hally.Api.Common;
using Hally.Domain.ChildMode;
using Hally.Domain.Common;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.ChildMode;

public record PairingCodeDto(string Code, DateTimeOffset ExpiresAt);

public record PairRequest(string Code, string? DeviceName);

/// <param name="Token">Send as the <c>X-Hally-Child</c> header. Shown once; only its hash is stored.</param>
public record PairResultDto(string Token, Guid FamilyId, ChildProfileDto Child);

public record ChildDeviceDto(Guid Id, string? Name, DateTimeOffset PairedAt, DateTimeOffset LastSeenAt);

public record ChildModeSettingsDto(bool RequireApproval);

public record ScreenReportRequest(int UsedSeconds);

public record MinutesRequest(int Minutes);

public class PairRequestValidator : AbstractValidator<PairRequest>
{
    public PairRequestValidator()
    {
        RuleFor(x => x.Code).NotEmpty().Matches("^[0-9]{6}$");
        RuleFor(x => x.DeviceName).MaximumLength(60);
    }
}

public class ScreenReportRequestValidator : AbstractValidator<ScreenReportRequest>
{
    public ScreenReportRequestValidator() => RuleFor(x => x.UsedSeconds).InclusiveBetween(0, 24 * 3600);
}

public class MinutesRequestValidator : AbstractValidator<MinutesRequest>
{
    public MinutesRequestValidator() => RuleFor(x => x.Minutes).InclusiveBetween(5, ScreenBonus.MaxMinutes);
}

/// <summary>Parent side of child mode: pairing codes, paired phones, approvals and extra screen minutes. Parents only.</summary>
[ApiController]
[Authorize(Policy = Policies.FamilyMember)]
[Route("api/v1/families/{familyId:guid}")]
public class ChildModeController(HallyDbContext db, ChildModeService childMode, TimeProvider clock) : ControllerBase
{
    /// <summary>A six-digit code to type on the child's phone, valid for ten minutes and once. A new code replaces the
    /// child's previous unused one.</summary>
    [HttpPost("children/{childId:guid}/pairing-code")]
    public async Task<PairingCodeDto> CreateCode(Guid familyId, Guid childId, CancellationToken ct)
    {
        await EnsureChild(familyId, childId, ct);
        var now = clock.GetUtcNow();
        await db.PairingCodes.Where(c => c.ChildId == childId && c.UsedAt == null).ExecuteDeleteAsync(ct);
        string code;
        string hash;
        do
        {
            code = RandomNumberGenerator.GetInt32(0, 1_000_000).ToString("D6");
            hash = Crypto.Sha256(code);
        }
        while (await db.PairingCodes.AnyAsync(c => c.CodeHash == hash && c.UsedAt == null && c.ExpiresAt > now, ct));

        var pairing = new PairingCode(familyId, childId, User.UserId(), hash, now);
        db.PairingCodes.Add(pairing);
        await db.SaveChangesAsync(ct);
        return new PairingCodeDto(code, pairing.ExpiresAt);
    }

    [HttpGet("children/{childId:guid}/devices")]
    public async Task<IReadOnlyList<ChildDeviceDto>> Devices(Guid familyId, Guid childId, CancellationToken ct)
    {
        await EnsureChild(familyId, childId, ct);
        return await db.ChildDevices.AsNoTracking().Where(d => d.ChildId == childId && d.RevokedAt == null).OrderBy(d => d.CreatedAt)
            .Select(d => new ChildDeviceDto(d.Id, d.Name, d.CreatedAt, d.LastSeenAt)).ToListAsync(ct);
    }

    /// <summary>Unpairs a phone: it stops working at its next request and goes back to the pairing screen.</summary>
    [HttpDelete("children/{childId:guid}/devices/{deviceId:guid}")]
    public async Task<IActionResult> Unpair(Guid familyId, Guid childId, Guid deviceId, CancellationToken ct)
    {
        var device = await db.ChildDevices.FirstOrDefaultAsync(d => d.Id == deviceId && d.ChildId == childId && d.FamilyId == familyId, ct)
                     ?? throw new NotFoundException("device.not_found", "Device not found.");
        device.Revoke(clock.GetUtcNow());
        await db.SaveChangesAsync(ct);
        return NoContent();
    }

    [HttpGet("child-mode")]
    public async Task<ChildModeSettingsDto> Settings(Guid familyId, CancellationToken ct) =>
        new(await db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.RequireChildApproval).FirstAsync(ct));

    [HttpPut("child-mode")]
    public async Task<ChildModeSettingsDto> UpdateSettings(Guid familyId, ChildModeSettingsDto request, CancellationToken ct)
    {
        var family = await db.Families.FirstAsync(f => f.Id == familyId, ct);
        family.SetChildApproval(request.RequireApproval);
        await db.SaveChangesAsync(ct);
        return new ChildModeSettingsDto(family.RequireChildApproval);
    }

    /// <summary>What the children marked done and waits for a parent, oldest first.</summary>
    [HttpGet("claims")]
    public Task<IReadOnlyList<ClaimDto>> Claims(Guid familyId, CancellationToken ct) => childMode.PendingAsync(familyId, ct);

    [HttpPost("claims/{claimId:guid}/approve")]
    public async Task<IReadOnlyList<ClaimDto>> Approve(Guid familyId, Guid claimId, CancellationToken ct)
    {
        await childMode.DecideAsync(familyId, claimId, true, User.UserId(), ct);
        return await childMode.PendingAsync(familyId, ct);
    }

    [HttpPost("claims/{claimId:guid}/reject")]
    public async Task<IReadOnlyList<ClaimDto>> Reject(Guid familyId, Guid claimId, CancellationToken ct)
    {
        await childMode.DecideAsync(familyId, claimId, false, User.UserId(), ct);
        return await childMode.PendingAsync(familyId, ct);
    }

    /// <summary>Today's screen time as the child's phone measured it.</summary>
    [CaregiverAllowed]
    [HttpGet("children/{childId:guid}/device-screen")]
    public Task<ChildScreenDto> Screen(Guid familyId, Guid childId, CancellationToken ct) => childMode.ScreenAsync(familyId, childId, ct);

    /// <summary>Extra minutes for today; a locked phone opens again at its next check.</summary>
    [HttpPost("children/{childId:guid}/screen-bonus")]
    public Task<ChildScreenDto> Grant(Guid familyId, Guid childId, MinutesRequest request, CancellationToken ct) =>
        childMode.GrantAsync(familyId, childId, request.Minutes, User.UserId(), ct);

    private async Task EnsureChild(Guid familyId, Guid childId, CancellationToken ct)
    {
        if (!await db.Children.AnyAsync(c => c.FamilyId == familyId && c.Id == childId, ct))
        {
            throw new NotFoundException("child.not_found", "Child not found.");
        }
    }
}

/// <summary>
/// What a paired child phone calls (header <c>X-Hally-Child</c>). The child is fixed by the device, so no route takes a
/// family or child id: a child phone can never reach another child or any parent endpoint.
/// </summary>
[ApiController]
[Authorize(Policy = ChildDeviceAuth.Policy)]
[Route("api/v1/child")]
public class ChildController(HallyDbContext db, ChildModeService childMode, TimeProvider clock) : ControllerBase
{
    public const string PairRateLimit = "child-pair";

    /// <summary>Pairs this phone with the code from a parent's phone. Wrong codes are rate limited per address.</summary>
    [AllowAnonymous]
    [EnableRateLimiting(PairRateLimit)]
    [HttpPost("pair")]
    public async Task<PairResultDto> Pair(PairRequest request, CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        var hash = Crypto.Sha256(request.Code);
        var code = await db.PairingCodes.FirstOrDefaultAsync(c => c.CodeHash == hash && c.UsedAt == null && c.ExpiresAt > now, ct)
                   ?? throw new DomainException("pairing.code_invalid", "This code is wrong or expired. Ask for a new one.");
        var child = await db.Children.AsNoTracking().FirstAsync(c => c.Id == code.ChildId, ct);
        code.Use(now);
        var token = Crypto.NewToken();
        db.ChildDevices.Add(new ChildDevice(code.FamilyId, code.ChildId, Crypto.Sha256(token), request.DeviceName, now));
        await db.SaveChangesAsync(ct);
        return new PairResultDto(token, code.FamilyId, new ChildProfileDto(child.Id, child.FirstName, child.Color, child.PhotoKey is not null));
    }

    [HttpGet("home")]
    public Task<ChildHomeDto> Home(CancellationToken ct) => childMode.HomeAsync(User.ChildFamilyId(), User.ChildId(), ct);

    [HttpPost("chores/{choreId:guid}/done")]
    public async Task<ChildHomeDto> ChoreDone(Guid choreId, CancellationToken ct)
    {
        await childMode.MarkDoneAsync(User.ChildFamilyId(), User.ChildId(), ClaimKind.Chore, choreId, ct);
        return await Home(ct);
    }

    [HttpPost("habits/{habitId:guid}/done")]
    public async Task<ChildHomeDto> HabitDone(Guid habitId, CancellationToken ct)
    {
        await childMode.MarkDoneAsync(User.ChildFamilyId(), User.ChildId(), ClaimKind.Habit, habitId, ct);
        return await Home(ct);
    }

    /// <summary>Spends cherries; 422 <c>points.not_enough</c> when the jar is short.</summary>
    [HttpPost("rewards/{rewardId:guid}/redeem")]
    public async Task<ChildHomeDto> Redeem(Guid rewardId, CancellationToken ct)
    {
        await childMode.RedeemAsync(User.ChildFamilyId(), User.ChildId(), rewardId, ct);
        return await Home(ct);
    }

    /// <summary>The phone's measured screen time today (its running total); the answer says whether to lock.</summary>
    [HttpPost("screen")]
    public Task<ChildScreenDto> Report(ScreenReportRequest request, CancellationToken ct) =>
        childMode.ReportUsageAsync(User.ChildFamilyId(), User.ChildId(), request.UsedSeconds, ct);

    [HttpGet("screen")]
    public Task<ChildScreenDto> Screen(CancellationToken ct) => childMode.ScreenAsync(User.ChildFamilyId(), User.ChildId(), ct);

    /// <summary>"Biraz daha süre isteyebilir miyim?": a note to the parents, at most one per ten minutes.</summary>
    [HttpPost("screen/request")]
    public async Task<IActionResult> RequestTime(MinutesRequest request, CancellationToken ct)
    {
        await childMode.RequestTimeAsync(User.ChildFamilyId(), User.ChildId(), request.Minutes, ct);
        return NoContent();
    }
}
