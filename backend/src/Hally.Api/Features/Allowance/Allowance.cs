using Hally.Api.Auth;
using Hally.Api.Common;
using Hally.Api.Features.Notifications;
using Hally.Domain.Allowance;
using Hally.Domain.Common;
using Hally.Domain.Expenses;
using Hally.Domain.Families;
using Hally.Domain.Notifications;
using Hally.Domain.Points;
using Hally.Domain.Users;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.Allowance;

/// <param name="RateCherries">"10 kiraz = 5 ₺": cherries ...</param>
/// <param name="RateAmount">... and their money value.</param>
/// <param name="WeeklyCherries">Added every Monday; 0 is off.</param>
public record AllowanceSettingsDto(int RateCherries, decimal RateAmount, string Currency, int WeeklyCherries, bool AddToExpenses);

public record SavingsGoalDto(string Title, string Emoji, int Cherries);

public record AllowanceRequestDto(Guid Id, Guid ChildId, string ChildName, int Cherries, decimal Amount, string Currency, string Status, DateTimeOffset CreatedAt,
    string? DecidedByName, DateTimeOffset? DecidedAt);

/// <param name="Kind">The ledger kind (Chore, Reward, Habit, Bonus, Mood, Bedtime, Activity, Allowance).</param>
/// <param name="Title">For Allowance: "weekly" or "converted".</param>
public record LedgerLineDto(string Kind, string Title, int Points, DateOnly Day);

/// <param name="WeeksToGoal">At the last four weeks' pace; null without a goal, when reached, or with no cherries lately.</param>
public record ChildSavingsDto(int Balance, SavingsGoalDto? Goal, int? WeeksToGoal, AllowanceSettingsDto Settings, AllowanceRequestDto? Pending,
    IReadOnlyList<LedgerLineDto> Recent);

/// <summary>The parents' Harçlık page for one child.</summary>
public record AllowanceDto(AllowanceSettingsDto Settings, SavingsGoalDto? Goal, int Balance, IReadOnlyList<AllowanceRequestDto> Requests);

public record ConvertRequest(int Cherries);

public record DecideAllowanceRequest(bool Paid);

public class AllowanceService(HallyDbContext db, NotificationPublisher publisher, TimeProvider clock, ILogger<AllowanceService> logger)
{
    public static AllowanceSettingsDto Settings(AllowancePlan p) => new(p.RateCherries, p.RateAmount, p.Currency, p.WeeklyCherries, p.AddToExpenses);

    public static SavingsGoalDto? Goal(AllowancePlan p) => p.GoalTitle is { } t && p.GoalCherries is { } c ? new SavingsGoalDto(t, p.GoalEmoji ?? "🎯", c) : null;

    /// <summary>The child's plan; a default one (not saved) until a parent or the child changes something.</summary>
    public async Task<AllowancePlan> PlanAsync(Guid familyId, Guid childId, bool track, CancellationToken ct)
    {
        var plan = track
            ? await db.AllowancePlans.FirstOrDefaultAsync(p => p.ChildId == childId, ct)
            : await db.AllowancePlans.AsNoTracking().FirstOrDefaultAsync(p => p.ChildId == childId, ct);
        if (plan is null)
        {
            plan = new AllowancePlan(familyId, childId, clock.GetUtcNow());
            if (track)
            {
                db.AllowancePlans.Add(plan);
            }
        }

        return plan;
    }

    public async Task<ChildSavingsDto> ChildAsync(Guid familyId, Guid childId, CancellationToken ct)
    {
        var plan = await PlanAsync(familyId, childId, false, ct);
        var tz = await db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.TimeZoneId).FirstAsync(ct);
        var today = FamilyTimeZone.LocalDate(clock.GetUtcNow(), tz);
        var entries = await db.PointEntries.AsNoTracking().Where(p => p.ChildId == childId).ToListAsync(ct);
        var balance = entries.Sum(e => e.Points);

        int? weeks = null;
        if (plan.GoalCherries is { } target && target > balance)
        {
            // Earned plus weekly allowance over the last 28 days; spending is the child's choice, so it is left out.
            var gained = entries.Where(e => e.Points > 0 && e.Day > today.AddDays(-28)).Sum(e => e.Points);
            var perWeek = gained / 4.0;
            weeks = perWeek >= 1 ? (int)Math.Ceiling((target - balance) / perWeek) : null;
        }

        var recent = entries.OrderByDescending(e => e.CreatedAt).Take(10)
            .Select(e => new LedgerLineDto(e.Kind.ToString(), e.Title, e.Points, e.Day)).ToList();
        var pending = (await RequestsAsync(familyId, childId, ct)).FirstOrDefault(r => r.Status == nameof(AllowanceStatus.Pending));
        return new ChildSavingsDto(balance, Goal(plan), weeks, Settings(plan), pending, recent);
    }

    public async Task SetGoalAsync(Guid familyId, Guid childId, SavingsGoalDto? goal, CancellationToken ct)
    {
        var plan = await PlanAsync(familyId, childId, true, ct);
        if (goal is null)
        {
            plan.ClearGoal();
        }
        else
        {
            plan.SetGoal(goal.Title, goal.Emoji, goal.Cherries);
        }

        await db.SaveChangesAsync(ct);
    }

    /// <summary>The child asks to turn cherries into pocket money. 422 <c>allowance.pending</c> while one waits,
    /// <c>points.not_enough</c>, <c>allowance.cherries_invalid</c> for a part step.</summary>
    public async Task ConvertAsync(Guid familyId, Guid childId, int cherries, CancellationToken ct)
    {
        var plan = await PlanAsync(familyId, childId, false, ct);
        var amount = plan.AmountFor(cherries);
        var balance = await db.PointEntries.Where(p => p.ChildId == childId).SumAsync(p => p.Points, ct);
        if (balance < cherries)
        {
            throw new DomainException("points.not_enough", $"Needs {cherries} cherries; there are {balance}.");
        }

        if (await db.AllowanceRequests.AnyAsync(r => r.ChildId == childId && r.Status == AllowanceStatus.Pending, ct))
        {
            throw new DomainException("allowance.pending", "A request is already waiting for a parent.");
        }

        var request = new AllowanceRequest(familyId, childId, cherries, amount, plan.Currency, clock.GetUtcNow());
        db.AllowanceRequests.Add(request);
        await db.SaveChangesAsync(ct);

        try
        {
            var name = await db.Children.AsNoTracking().Where(c => c.Id == childId).Select(c => c.FirstName).FirstAsync(ct);
            foreach (var p in await ParentsAsync(familyId, ct))
            {
                var tr = Locales.IsTurkish(p.Locale);
                var money = Money(amount, plan.Currency, tr);
                await publisher.AddAsync(p.Id, familyId, NotificationKind.AllowanceRequest,
                    tr ? $"{name} harçlık istiyor" : $"{name} asks for pocket money",
                    tr ? $"{cherries} kiraz = {money}" : $"{cherries} cherries = {money}", null, childId, $"allow:{request.Id:N}:{p.Id:N}", ct);
            }

            await db.SaveChangesAsync(ct);
            await publisher.FlushPushAsync(ct);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Allowance notification failed");
        }
    }

    /// <summary>"Ödedim": the cherries leave the jar and, if the family wants, the money goes to Harcamalar.
    /// "Şimdi değil": nothing changes. Either way the child sees it.</summary>
    public async Task<AllowanceRequestDto> DecideAsync(Guid familyId, Guid requestId, Guid userId, bool paid, CancellationToken ct)
    {
        var request = await db.AllowanceRequests.FirstOrDefaultAsync(r => r.Id == requestId && r.FamilyId == familyId, ct)
                      ?? throw new NotFoundException("allowance.not_found", "Request not found.");
        var now = clock.GetUtcNow();
        var tz = await db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.TimeZoneId).FirstAsync(ct);
        var today = FamilyTimeZone.LocalDate(now, tz);
        Guid? expenseId = null;
        if (paid)
        {
            var balance = await db.PointEntries.Where(p => p.ChildId == request.ChildId).SumAsync(p => p.Points, ct);
            db.PointEntries.Add(PointEntry.ForConversion(familyId, request.ChildId, request.Cherries, balance, userId, today, now));

            var plan = await PlanAsync(familyId, request.ChildId, false, ct);
            if (plan.AddToExpenses)
            {
                var adults = await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == familyId && m.Role != FamilyRole.Caregiver).Select(m => m.UserId).ToListAsync(ct);
                var name = await db.Children.AsNoTracking().Where(c => c.Id == request.ChildId).Select(c => c.FirstName).FirstAsync(ct);
                var turkish = Locales.IsTurkish(await db.Users.AsNoTracking().Where(u => u.Id == userId).Select(u => u.Locale).FirstAsync(ct));
                var expense = new Expense(familyId, turkish ? $"Harçlık · {name}" : $"Pocket money · {name}", request.Amount, ExpenseCategory.Other, today, userId,
                    adults, request.ChildId, turkish ? $"{request.Cherries} kiraz" : $"{request.Cherries} cherries", userId, now);
                db.Expenses.Add(expense);
                expenseId = expense.Id;
            }
        }

        request.Decide(paid, userId, expenseId, now);
        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (DbUpdateConcurrencyException)
        {
            throw new DomainException("allowance.already_decided", "This request was already answered.");
        }

        return (await RequestsAsync(familyId, request.ChildId, ct)).First(r => r.Id == requestId);
    }

    public async Task<IReadOnlyList<AllowanceRequestDto>> RequestsAsync(Guid familyId, Guid? childId, CancellationToken ct)
    {
        var since = clock.GetUtcNow().AddDays(-60);
        var query = db.AllowanceRequests.AsNoTracking().Where(r => r.FamilyId == familyId && (r.Status == AllowanceStatus.Pending || r.CreatedAt > since));
        if (childId is { } c)
        {
            query = query.Where(r => r.ChildId == c);
        }

        var rows = await query.OrderByDescending(r => r.CreatedAt).Take(30)
            .Join(db.Children.AsNoTracking(), r => r.ChildId, k => k.Id, (r, k) => new { r, k.FirstName })
            .GroupJoin(db.Users.AsNoTracking(), x => x.r.DecidedByUserId, u => u.Id, (x, us) => new { x.r, x.FirstName, us })
            .SelectMany(x => x.us.DefaultIfEmpty(), (x, u) => new { x.r, x.FirstName, By = u == null ? null : u.DisplayName })
            .ToListAsync(ct);
        return rows.OrderByDescending(x => x.r.CreatedAt).Select(x => new AllowanceRequestDto(x.r.Id, x.r.ChildId, x.FirstName, x.r.Cherries, x.r.Amount, x.r.Currency,
            x.r.Status.ToString(), x.r.CreatedAt, x.By?.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault(), x.r.DecidedAt)).ToList();
    }

    /// <summary>Hangfire: adds the weekly allowance on Monday (family-local), once per week and child.</summary>
    public async Task<int> WeeklyAsync(CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        var plans = await db.AllowancePlans.AsTracking().Where(p => p.WeeklyCherries > 0).ToListAsync(ct);
        var familyIds = plans.Select(p => p.FamilyId).Distinct().ToList();
        var zones = await db.Families.AsNoTracking().Where(f => familyIds.Contains(f.Id)).ToDictionaryAsync(f => f.Id, f => f.TimeZoneId, ct);
        var added = 0;
        foreach (var plan in plans)
        {
            var today = FamilyTimeZone.LocalDate(now, zones[plan.FamilyId]);
            var monday = today.AddDays(-(((int)today.DayOfWeek + 6) % 7));
            if (plan.TakeWeek(monday))
            {
                db.PointEntries.Add(PointEntry.ForWeeklyAllowance(plan.FamilyId, plan.ChildId, plan.WeeklyCherries, today, now));
                added++;
            }
        }

        await db.SaveChangesAsync(ct);
        return added;
    }

    public static string Money(decimal amount, string currency, bool turkish)
    {
        var text = amount.ToString(amount == decimal.Truncate(amount) ? "0" : "0.00", turkish ? new System.Globalization.CultureInfo("tr-TR") : System.Globalization.CultureInfo.InvariantCulture);
        return currency == "TRY" ? (turkish ? $"{text} ₺" : $"₺{text}") : $"{text} {currency}";
    }

    private async Task<List<(Guid Id, string Locale)>> ParentsAsync(Guid familyId, CancellationToken ct) =>
        (await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == familyId && m.Role != FamilyRole.Caregiver)
            .Join(db.Users.AsNoTracking(), m => m.UserId, u => u.Id, (m, u) => new { u.Id, u.Locale }).ToListAsync(ct))
        .Select(p => (p.Id, p.Locale)).ToList();
}

/// <summary>Parents: Çocuklar → Ela → Harçlık. Caregivers don't see money.</summary>
[ApiController]
[Authorize(Policy = Policies.FamilyMember)]
[Route("api/v1/families/{familyId:guid}")]
public class AllowanceController(HallyDbContext db, AllowanceService allowance) : ControllerBase
{
    [HttpGet("children/{childId:guid}/allowance")]
    public async Task<AllowanceDto> Get(Guid familyId, Guid childId, CancellationToken ct)
    {
        await EnsureChild(familyId, childId, ct);
        var plan = await allowance.PlanAsync(familyId, childId, false, ct);
        var balance = await db.PointEntries.Where(p => p.ChildId == childId).SumAsync(p => p.Points, ct);
        return new AllowanceDto(AllowanceService.Settings(plan), AllowanceService.Goal(plan), balance, await allowance.RequestsAsync(familyId, childId, ct));
    }

    [HttpPut("children/{childId:guid}/allowance")]
    public async Task<AllowanceDto> Put(Guid familyId, Guid childId, AllowanceSettingsDto request, CancellationToken ct)
    {
        await EnsureChild(familyId, childId, ct);
        var plan = await allowance.PlanAsync(familyId, childId, true, ct);
        plan.Update(request.RateCherries, request.RateAmount, "TRY", request.WeeklyCherries, request.AddToExpenses);
        await db.SaveChangesAsync(ct);
        return await Get(familyId, childId, ct);
    }

    /// <summary>Open conversion requests of all children (for Today).</summary>
    [HttpGet("allowance-requests")]
    public async Task<IReadOnlyList<AllowanceRequestDto>> Requests(Guid familyId, CancellationToken ct) =>
        (await allowance.RequestsAsync(familyId, null, ct)).Where(r => r.Status == nameof(AllowanceStatus.Pending)).ToList();

    /// <summary>"Ödedim" (paid: true) or "Şimdi değil" (paid: false).</summary>
    [HttpPost("allowance-requests/{requestId:guid}/decide")]
    public Task<AllowanceRequestDto> Decide(Guid familyId, Guid requestId, DecideAllowanceRequest request, CancellationToken ct) =>
        allowance.DecideAsync(familyId, requestId, User.UserId(), request.Paid, ct);

    private async Task EnsureChild(Guid familyId, Guid childId, CancellationToken ct)
    {
        if (!await db.Children.AnyAsync(c => c.Id == childId && c.FamilyId == familyId, ct))
        {
            throw new NotFoundException("child.not_found", "Child not found.");
        }
    }
}

/// <summary>The child's phone: Birikimim (savings goal) and "Harçlığa çevir".</summary>
[ApiController]
[Authorize(Policy = ChildDeviceAuth.Policy)]
[Route("api/v1/child/savings")]
public class ChildSavingsController(AllowanceService allowance) : ControllerBase
{
    [HttpGet]
    public Task<ChildSavingsDto> Get(CancellationToken ct) => allowance.ChildAsync(User.ChildFamilyId(), User.ChildId(), ct);

    [HttpPut("goal")]
    public async Task<ChildSavingsDto> SetGoal(SavingsGoalDto request, CancellationToken ct)
    {
        await allowance.SetGoalAsync(User.ChildFamilyId(), User.ChildId(), request, ct);
        return await Get(ct);
    }

    [HttpDelete("goal")]
    public async Task<ChildSavingsDto> ClearGoal(CancellationToken ct)
    {
        await allowance.SetGoalAsync(User.ChildFamilyId(), User.ChildId(), null, ct);
        return await Get(ct);
    }

    [HttpPost("convert")]
    public async Task<ChildSavingsDto> Convert(ConvertRequest request, CancellationToken ct)
    {
        await allowance.ConvertAsync(User.ChildFamilyId(), User.ChildId(), request.Cherries, ct);
        return await Get(ct);
    }
}
