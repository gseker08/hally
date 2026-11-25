using FluentValidation;
using Hally.Api.Auth;
using Hally.Api.Common;
using Hally.Api.Features.Messages;
using Hally.Api.Features.Notifications;
using Hally.Domain.Shopping;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.Shopping;

public record ShoppingItemDto(Guid Id, string Text, string? Quantity, Guid? AddedByUserId, string? AddedByName, DateTimeOffset CreatedAt,
    DateTimeOffset? CheckedAt, Guid? CheckedByUserId, string? CheckedByName);

/// <param name="Open">Still to buy, oldest first.</param>
/// <param name="Checked">Bought, newest first, until someone clears them.</param>
public record ShoppingListDto(IReadOnlyList<ShoppingItemDto> Open, IReadOnlyList<ShoppingItemDto> Checked);

/// <summary>Several lines at once ("süt, ekmek, 2 kg elma" or one per line) are split into items.</summary>
public record AddShoppingItemsRequest(string Text, string? Quantity = null);

/// <summary>Null fields stay as they are.</summary>
public record UpdateShoppingItemRequest(string? Text = null, string? Quantity = null, bool? Checked = null);

public record AddShoppingResult(IReadOnlyList<ShoppingItemDto> Added, IReadOnlyList<ShoppingItemDto> AlreadyOnList, ShoppingListDto List);

/// <summary>Live note that the family's shopping list changed; apps reload it.</summary>
public record ShoppingEvent(Guid FamilyId);

public class AddShoppingItemsRequestValidator : AbstractValidator<AddShoppingItemsRequest>
{
    public AddShoppingItemsRequestValidator()
    {
        RuleFor(x => x.Text).NotEmpty().MaximumLength(1000);
        RuleFor(x => x.Quantity).MaximumLength(ShoppingItem.MaxQuantityLength);
    }
}

/// <summary>
/// The family's shared shopping list: anyone adds, whoever is at the shop checks items off, and everybody's open
/// app updates at once (<c>ShoppingChanged</c> on <c>/hubs/chat</c>). "I'm going shopping" pushes the others so they
/// can add what they need.
/// </summary>
[ApiController]
[Authorize(Policy = Policies.FamilyMember)]
[CaregiverAllowed]
[Route("api/v1/families/{familyId:guid}/shopping")]
public class ShoppingController(HallyDbContext db, IHubContext<ChatHub, IChatClient> hub, IPushSender push, TimeProvider clock, ILogger<ShoppingController> logger)
    : ControllerBase
{
    public const int MaxOpenItems = 300;

    [HttpGet]
    public Task<ShoppingListDto> Get(Guid familyId, CancellationToken ct) => LoadAsync(familyId, ct);

    /// <summary>Adds one or more items. An item already open on the list (same text, any case) is not added twice.</summary>
    [HttpPost("items")]
    [ProducesResponseType<AddShoppingResult>(201)]
    public async Task<IActionResult> Add(Guid familyId, AddShoppingItemsRequest request, CancellationToken ct)
    {
        var lines = SplitLines(request.Text);
        if (lines.Count == 0)
        {
            throw new Domain.Common.DomainException("shopping.text_invalid", "Nothing to add.");
        }

        var open = await db.ShoppingItems.Where(i => i.FamilyId == familyId && i.CheckedAt == null).ToListAsync(ct);
        if (open.Count + lines.Count > MaxOpenItems)
        {
            throw new Domain.Common.DomainException("shopping.too_many", $"The list holds at most {MaxOpenItems} items.");
        }

        var now = clock.GetUtcNow();
        var added = new List<ShoppingItem>();
        var existing = new List<ShoppingItem>();
        foreach (var line in lines)
        {
            var key = ShoppingItem.Normalize(line);
            if (open.Concat(added).FirstOrDefault(i => ShoppingItem.Normalize(i.Text) == key) is { } dup)
            {
                if (!added.Contains(dup))
                {
                    existing.Add(dup);
                }

                continue;
            }

            // A single line takes the quantity field; several lines keep their own text as typed.
            // One microsecond apart, so the list keeps the order they were typed in (Postgres stores microseconds).
            var item = new ShoppingItem(familyId, User.UserId(), line, lines.Count == 1 ? request.Quantity : null, now.AddMicroseconds(added.Count));
            db.ShoppingItems.Add(item);
            added.Add(item);
        }

        await db.SaveChangesAsync(ct);
        if (added.Count > 0)
        {
            await AnnounceAsync(familyId, ct);
        }

        var list = await LoadAsync(familyId, ct);
        var all = list.Open.ToDictionary(i => i.Id);
        return StatusCode(201, new AddShoppingResult(
            added.Select(i => all[i.Id]).ToList(),
            existing.Where(i => all.ContainsKey(i.Id)).Select(i => all[i.Id]).ToList(),
            list));
    }

    [HttpPatch("items/{itemId:guid}")]
    public async Task<ShoppingListDto> Update(Guid familyId, Guid itemId, UpdateShoppingItemRequest request, CancellationToken ct)
    {
        var item = await Find(familyId, itemId, ct);
        if (request.Text is not null || request.Quantity is not null)
        {
            item.Edit(request.Text ?? item.Text, request.Quantity ?? item.Quantity);
        }

        if (request.Checked is { } check)
        {
            if (check)
            {
                item.Check(User.UserId(), clock.GetUtcNow());
            }
            else
            {
                item.Uncheck();
            }
        }

        await db.SaveChangesAsync(ct);
        await AnnounceAsync(familyId, ct);
        return await LoadAsync(familyId, ct);
    }

    [HttpDelete("items/{itemId:guid}")]
    public async Task<ShoppingListDto> Delete(Guid familyId, Guid itemId, CancellationToken ct)
    {
        db.ShoppingItems.Remove(await Find(familyId, itemId, ct));
        await db.SaveChangesAsync(ct);
        await AnnounceAsync(familyId, ct);
        return await LoadAsync(familyId, ct);
    }

    /// <summary>Removes every checked item.</summary>
    [HttpPost("clear-checked")]
    public async Task<ShoppingListDto> ClearChecked(Guid familyId, CancellationToken ct)
    {
        await db.ShoppingItems.Where(i => i.FamilyId == familyId && i.CheckedAt != null).ExecuteDeleteAsync(ct);
        await AnnounceAsync(familyId, ct);
        return await LoadAsync(familyId, ct);
    }

    /// <summary>"I'm going shopping": pushes the other adults so they can add what they need. At most once per
    /// 15 minutes per person, so a double tap does not ring twice.</summary>
    [HttpPost("heading-out")]
    public async Task<IActionResult> HeadingOut(Guid familyId, CancellationToken ct)
    {
        var me = User.UserId();
        var now = clock.GetUtcNow();
        var key = $"shopping-out:{familyId:N}:{me:N}";
        if (HeadingOutLog.TryGetValue(key, out var last) && now - last < TimeSpan.FromMinutes(15))
        {
            return Accepted(new { sent = false });
        }

        HeadingOutLog[key] = now;
        try
        {
            var name = await db.Users.AsNoTracking().Where(u => u.Id == me).Select(u => u.DisplayName).FirstAsync(ct);
            var first = name.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? name;
            var openCount = await db.ShoppingItems.CountAsync(i => i.FamilyId == familyId && i.CheckedAt == null, ct);
            var others = await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == familyId && m.UserId != me)
                .Join(db.Users.AsNoTracking(), m => m.UserId, u => u.Id, (m, u) => new { u.Id, u.Locale }).ToListAsync(ct);
            var ids = others.Select(o => o.Id).ToList();
            var devices = await db.Devices.AsNoTracking().Where(d => ids.Contains(d.UserId)).ToListAsync(ct);
            var invalid = new List<string>();
            foreach (var user in others)
            {
                var tokens = devices.Where(d => d.UserId == user.Id).Select(d => d.Token).ToList();
                if (tokens.Count == 0)
                {
                    continue;
                }

                var tr = user.Locale != "en";
                var title = tr ? $"{first} alışverişe çıkıyor" : $"{first} is going shopping";
                var body = tr ? $"Listede {openCount} ürün var. Eklemek istediğin bir şey var mı?" : $"{openCount} items on the list. Anything to add?";
                var data = new Dictionary<string, string> { ["kind"] = "ShoppingHeadingOut", ["familyId"] = familyId.ToString() };
                invalid.AddRange(await push.SendAsync(tokens, new PushMessage(title, body, data), ct));
            }

            if (invalid.Count > 0)
            {
                await db.Devices.Where(d => invalid.Contains(d.Token)).ExecuteDeleteAsync(ct);
            }
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Shopping push failed");
        }

        return Accepted(new { sent = true });
    }

    /// <summary>Last "heading out" per family member, kept in memory: losing it on a restart only allows one more push.</summary>
    private static readonly System.Collections.Concurrent.ConcurrentDictionary<string, DateTimeOffset> HeadingOutLog = new();

    /// <summary>Splits on new lines and commas (but not decimal commas such as "1,5 kg"); empty parts are dropped and
    /// each part is cut to the item limit.</summary>
    public static List<string> SplitLines(string text) =>
        System.Text.RegularExpressions.Regex.Split(text, @"[\r\n]+|(?<!\d),|,(?!\d)")
            .Select(l => l.Trim())
            .Select(l => l.TrimStart('-', '*', '•', ' ').Trim())
            .Where(l => l.Length > 0)
            .Select(l => l.Length > ShoppingItem.MaxTextLength ? l[..ShoppingItem.MaxTextLength] : l)
            .ToList();

    private async Task<ShoppingItem> Find(Guid familyId, Guid itemId, CancellationToken ct) =>
        await db.ShoppingItems.FirstOrDefaultAsync(i => i.FamilyId == familyId && i.Id == itemId, ct)
        ?? throw new NotFoundException("shopping.not_found", "Item not found.");

    private async Task<ShoppingListDto> LoadAsync(Guid familyId, CancellationToken ct)
    {
        var items = await db.ShoppingItems.AsNoTracking().Where(i => i.FamilyId == familyId).ToListAsync(ct);
        var userIds = items.SelectMany(i => new[] { i.AddedByUserId, i.CheckedByUserId }).OfType<Guid>().Distinct().ToList();
        var names = await db.Users.AsNoTracking().Where(u => userIds.Contains(u.Id)).ToDictionaryAsync(u => u.Id, u => u.DisplayName, ct);
        ShoppingItemDto Dto(ShoppingItem i) => new(i.Id, i.Text, i.Quantity, i.AddedByUserId,
            i.AddedByUserId is { } a ? names.GetValueOrDefault(a) : null, i.CreatedAt, i.CheckedAt, i.CheckedByUserId,
            i.CheckedByUserId is { } c ? names.GetValueOrDefault(c) : null);
        return new ShoppingListDto(
            items.Where(i => !i.IsChecked).OrderBy(i => i.CreatedAt).ThenBy(i => i.Text).Select(Dto).ToList(),
            items.Where(i => i.IsChecked).OrderByDescending(i => i.CheckedAt).Select(Dto).ToList());
    }

    private async Task AnnounceAsync(Guid familyId, CancellationToken ct)
    {
        try
        {
            var adults = await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == familyId).Select(m => m.UserId).ToListAsync(ct);
            await hub.Clients.Groups(adults.Select(ChatHub.UserGroup).ToList()).ShoppingChanged(new ShoppingEvent(familyId));
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Realtime shopping event failed");
        }
    }
}
