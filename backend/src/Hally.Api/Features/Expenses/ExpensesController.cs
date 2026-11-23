using System.Globalization;
using FluentValidation;
using Hally.Api.Auth;
using Hally.Api.Common;
using Hally.Api.Features.Messages;
using Hally.Domain.Common;
using Hally.Domain.Expenses;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.Expenses;

public record ExpenseDto(Guid Id, string Title, decimal Amount, string Category, DateOnly Date, Guid PaidByUserId, string? PaidByName, Guid? ChildId,
    string? Note, decimal MyShare);

public record SettlementDto(Guid Id, Guid FromUserId, string? FromName, Guid ToUserId, string? ToName, decimal Amount, DateOnly Date);

public record CategoryTotalDto(string Category, decimal Amount);

/// <param name="Net">Positive: the others owe this adult; negative: this adult owes.</param>
public record ExpenseBalanceDto(Guid UserId, string Name, decimal Net);

/// <summary>Who should pay whom to even out (always for two adults; for more, the biggest debtor to the biggest creditor).</summary>
public record SettleSuggestionDto(Guid FromUserId, string FromName, Guid ToUserId, string ToName, decimal Amount);

/// <param name="Balances">All-time, not just this month.</param>
public record ExpenseMonthDto(string Month, string Currency, decimal Total, IReadOnlyList<CategoryTotalDto> ByCategory, IReadOnlyList<ExpenseDto> Expenses,
    IReadOnlyList<SettlementDto> Settlements, IReadOnlyList<ExpenseBalanceDto> Balances, SettleSuggestionDto? Suggestion);

public record AddExpenseRequest(string Title, decimal Amount, ExpenseCategory Category = ExpenseCategory.Other, DateOnly? Date = null,
    Guid? PaidByUserId = null, Guid? ChildId = null, string? Note = null);

/// <summary>I paid <see cref="ToUserId"/> this much.</summary>
public record SettleRequest(Guid ToUserId, decimal Amount);

/// <summary>Live note that expenses changed; apps reload.</summary>
public record ExpensesEvent(Guid FamilyId);

public class AddExpenseRequestValidator : AbstractValidator<AddExpenseRequest>
{
    public AddExpenseRequestValidator()
    {
        RuleFor(x => x.Title).NotEmpty().MaximumLength(80);
        RuleFor(x => x.Amount).GreaterThan(0).LessThanOrEqualTo(Expense.MaxAmount);
        RuleFor(x => x.Note).MaximumLength(200);
    }
}

/// <summary>
/// Shared child expenses between the family's adults: who paid what, each one's share (equal split), the running
/// balance and settling up. Hally moves no money; it only keeps the record. Live on <c>/hubs/chat</c> (<c>ExpensesChanged</c>).
/// </summary>
[ApiController]
[Authorize(Policy = Policies.FamilyMember)]
[Route("api/v1/families/{familyId:guid}/expenses")]
public class ExpensesController(HallyDbContext db, IHubContext<ChatHub, IChatClient> hub, TimeProvider clock, ILogger<ExpensesController> logger) : ControllerBase
{
    public const string Currency = "TRY";

    /// <summary>One month (<c>yyyy-MM</c>, default this month) of expenses and settlements, plus all-time balances.</summary>
    [HttpGet]
    public async Task<ExpenseMonthDto> Month(Guid familyId, [FromQuery] string? month, CancellationToken ct)
    {
        var today = await Today(familyId, ct);
        var first = month is null
            ? new DateOnly(today.Year, today.Month, 1)
            : DateOnly.TryParseExact(month + "-01", "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var m)
                ? m
                : throw new DomainException("expense.month_invalid", "Month must be yyyy-MM.");
        var next = first.AddMonths(1);
        var me = User.UserId();

        var all = await db.Expenses.AsNoTracking().Where(e => e.FamilyId == familyId).ToListAsync(ct);
        var settlements = await db.Settlements.AsNoTracking().Where(s => s.FamilyId == familyId).ToListAsync(ct);
        var adults = await db.FamilyMembers.AsNoTracking().Where(f => f.FamilyId == familyId)
            .Join(db.Users.AsNoTracking(), f => f.UserId, u => u.Id, (f, u) => new { u.Id, u.DisplayName, f.CreatedAt }).OrderBy(a => a.CreatedAt).ToListAsync(ct);
        var ids = all.Select(e => e.PaidByUserId).Concat(settlements.SelectMany(s => new[] { s.FromUserId, s.ToUserId })).Distinct().ToList();
        var names = await db.Users.AsNoTracking().Where(u => ids.Contains(u.Id)).ToDictionaryAsync(u => u.Id, u => u.DisplayName, ct);
        foreach (var a in adults)
        {
            names[a.Id] = a.DisplayName;
        }

        var inMonth = all.Where(e => e.Date >= first && e.Date < next).OrderByDescending(e => e.Date).ThenByDescending(e => e.CreatedAt).ToList();
        var net = Settlement.Balances(all, settlements);
        var balances = adults.Select(a => new ExpenseBalanceDto(a.Id, a.DisplayName, net.GetValueOrDefault(a.Id))).ToList();
        var debtor = balances.Where(b => b.Net < 0).OrderBy(b => b.Net).FirstOrDefault();
        var creditor = balances.Where(b => b.Net > 0).OrderByDescending(b => b.Net).FirstOrDefault();
        var suggestion = debtor is null || creditor is null
            ? null
            : new SettleSuggestionDto(debtor.UserId, debtor.Name, creditor.UserId, creditor.Name, Math.Min(-debtor.Net, creditor.Net));

        return new ExpenseMonthDto(
            first.ToString("yyyy-MM", CultureInfo.InvariantCulture),
            Currency,
            inMonth.Sum(e => e.Amount),
            inMonth.GroupBy(e => e.Category).Select(g => new CategoryTotalDto(g.Key.ToString(), g.Sum(e => e.Amount))).OrderByDescending(c => c.Amount).ToList(),
            inMonth.Select(e => new ExpenseDto(e.Id, e.Title, e.Amount, e.Category.ToString(), e.Date, e.PaidByUserId, names.GetValueOrDefault(e.PaidByUserId),
                e.ChildId, e.Note, e.ShareOf(me))).ToList(),
            settlements.Where(s => s.Date >= first && s.Date < next).OrderByDescending(s => s.Date)
                .Select(s => new SettlementDto(s.Id, s.FromUserId, names.GetValueOrDefault(s.FromUserId), s.ToUserId, names.GetValueOrDefault(s.ToUserId), s.Amount, s.Date))
                .ToList(),
            balances,
            suggestion);
    }

    [HttpPost]
    [ProducesResponseType<ExpenseMonthDto>(201)]
    public async Task<IActionResult> Add(Guid familyId, AddExpenseRequest request, CancellationToken ct)
    {
        var adults = await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == familyId).Select(m => m.UserId).ToListAsync(ct);
        var payer = request.PaidByUserId ?? User.UserId();
        if (!adults.Contains(payer))
        {
            throw new DomainException("expense.payer_not_member", "Pick an adult of this family.");
        }

        if (request.ChildId is { } c && !await db.Children.AnyAsync(x => x.FamilyId == familyId && x.Id == c, ct))
        {
            throw new NotFoundException("child.not_found", "Child not found.");
        }

        var today = await Today(familyId, ct);
        var date = request.Date ?? today;
        if (date > today || date < today.AddYears(-1))
        {
            throw new DomainException("expense.date_invalid", "Date must be within the last year and not in the future.");
        }

        var expense = new Expense(familyId, request.Title, request.Amount, request.Category, date, payer, adults, request.ChildId, request.Note,
            User.UserId(), clock.GetUtcNow());
        db.Expenses.Add(expense);
        await db.SaveChangesAsync(ct);
        await Announce(familyId, ct);
        return StatusCode(201, await Month(familyId, date.ToString("yyyy-MM", CultureInfo.InvariantCulture), ct));
    }

    [HttpDelete("{expenseId:guid}")]
    public async Task<ExpenseMonthDto> Delete(Guid familyId, Guid expenseId, CancellationToken ct)
    {
        var expense = await db.Expenses.FirstOrDefaultAsync(e => e.Id == expenseId && e.FamilyId == familyId, ct)
                      ?? throw new NotFoundException("expense.not_found", "Expense not found.");
        db.Expenses.Remove(expense);
        await db.SaveChangesAsync(ct);
        await Announce(familyId, ct);
        return await Month(familyId, expense.Date.ToString("yyyy-MM", CultureInfo.InvariantCulture), ct);
    }

    /// <summary>Records that I paid another adult.</summary>
    [HttpPost("settlements")]
    [ProducesResponseType<ExpenseMonthDto>(201)]
    public async Task<IActionResult> Settle(Guid familyId, SettleRequest request, CancellationToken ct)
    {
        if (!await db.FamilyMembers.AnyAsync(m => m.FamilyId == familyId && m.UserId == request.ToUserId, ct))
        {
            throw new DomainException("expense.payer_not_member", "Pick an adult of this family.");
        }

        db.Settlements.Add(new Settlement(familyId, User.UserId(), request.ToUserId, request.Amount, await Today(familyId, ct), clock.GetUtcNow()));
        await db.SaveChangesAsync(ct);
        await Announce(familyId, ct);
        return StatusCode(201, await Month(familyId, null, ct));
    }

    [HttpDelete("settlements/{settlementId:guid}")]
    public async Task<ExpenseMonthDto> DeleteSettlement(Guid familyId, Guid settlementId, CancellationToken ct)
    {
        await db.Settlements.Where(s => s.Id == settlementId && s.FamilyId == familyId).ExecuteDeleteAsync(ct);
        await Announce(familyId, ct);
        return await Month(familyId, null, ct);
    }

    private async Task<DateOnly> Today(Guid familyId, CancellationToken ct)
    {
        var tz = await db.Families.AsNoTracking().Where(f => f.Id == familyId).Select(f => f.TimeZoneId).FirstAsync(ct);
        return FamilyTimeZone.LocalDate(clock.GetUtcNow(), tz);
    }

    private async Task Announce(Guid familyId, CancellationToken ct)
    {
        try
        {
            var adults = await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == familyId).Select(m => m.UserId).ToListAsync(ct);
            await hub.Clients.Groups(adults.Select(ChatHub.UserGroup).ToList()).ExpensesChanged(new ExpensesEvent(familyId));
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Realtime expenses event failed");
        }
    }
}
