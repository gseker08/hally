using FluentValidation;
using Hally.Api.Auth;
using Hally.Api.Common;
using Hally.Api.Features.Notifications;
using Hally.Domain.Common;
using Hally.Domain.Messaging;
using Hally.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.Messages;

/// <param name="Key">"family" for the family chat, otherwise the other adult's user id.</param>
/// <param name="OtherName">Direct chats only. Null for the family chat.</param>
public record ChatSummaryDto(string Key, string Kind, Guid? OtherUserId, string? OtherName, MessageDto? LastMessage, int Unread);
public record ChatListDto(IReadOnlyList<ChatSummaryDto> Chats, int TotalUnread);

/// <param name="SenderName">Null when the sender is no longer in the family.</param>
/// <param name="LinkTitle">Title of the linked task or event, when it still exists.</param>
public record MessageDto(Guid Id, Guid SenderUserId, string? SenderName, string Body, DateTimeOffset CreatedAt, Guid? TaskId, Guid? EventId, string? LinkTitle);
public record SendMessageRequest(string Body, Guid? TaskId = null, Guid? EventId = null);

public class SendMessageRequestValidator : AbstractValidator<SendMessageRequest>
{
    public SendMessageRequestValidator()
    {
        RuleFor(x => x.Body).NotEmpty().MaximumLength(FamilyMessage.MaxLength);
        RuleFor(x => x).Must(x => x.TaskId is null || x.EventId is null).WithMessage("Link a task or an event, not both.");
    }
}

/// <summary>
/// Messages between the adults of a family: one family chat everybody shares, plus a direct chat for every pair.
/// Chats are addressed by key ("family" or the other adult's id) and created on the first message.
/// </summary>
[ApiController]
[Authorize(Policy = Policies.FamilyMember)]
[Route("api/v1/families/{familyId:guid}/chats")]
public class MessagesController(HallyDbContext db, MessagePush push, TimeProvider clock) : ControllerBase
{
    public const int MaxPage = 100;

    [HttpGet]
    public async Task<ActionResult<ChatListDto>> List(Guid familyId, CancellationToken ct)
    {
        var me = User.UserId();
        var members = await Members(familyId, ct);
        var joinedAt = members.First(m => m.UserId == me).JoinedAt;
        var threads = await db.MessageThreads.AsNoTracking()
            .Where(t => t.FamilyId == familyId && (t.Kind == MessageThreadKind.Family || t.UserA == me || t.UserB == me))
            .ToListAsync(ct);
        var threadIds = threads.Select(t => t.Id).ToList();
        var reads = await db.MessageReadStates.AsNoTracking().Where(r => r.UserId == me && threadIds.Contains(r.ThreadId))
            .ToDictionaryAsync(r => r.ThreadId, r => r.LastReadAt, ct);
        var names = members.ToDictionary(m => m.UserId, m => m.DisplayName);

        async Task<(MessageDto? Last, int Unread)> Stats(MessageThread? thread)
        {
            if (thread is null)
            {
                return (null, 0);
            }

            var last = await db.FamilyMessages.AsNoTracking().Where(m => m.ThreadId == thread.Id)
                .OrderByDescending(m => m.CreatedAt).ThenByDescending(m => m.Id).FirstOrDefaultAsync(ct);
            var since = reads.TryGetValue(thread.Id, out var r) ? r : joinedAt;
            var unread = await db.FamilyMessages.CountAsync(m => m.ThreadId == thread.Id && m.SenderUserId != me && m.CreatedAt > since, ct);
            return (last is null ? null : ToDto(last, names, null), unread);
        }

        var chats = new List<ChatSummaryDto>();
        var family = await Stats(threads.FirstOrDefault(t => t.Kind == MessageThreadKind.Family));
        chats.Add(new ChatSummaryDto(MessageThread.FamilyKey, nameof(MessageThreadKind.Family), null, null, family.Last, family.Unread));

        var direct = new List<ChatSummaryDto>();
        foreach (var other in members.Where(m => m.UserId != me))
        {
            var key = MessageThread.DirectKey(me, other.UserId);
            var stats = await Stats(threads.FirstOrDefault(t => t.Key == key));
            direct.Add(new ChatSummaryDto(other.UserId.ToString(), nameof(MessageThreadKind.Direct), other.UserId, other.DisplayName, stats.Last, stats.Unread));
        }

        chats.AddRange(direct.OrderByDescending(c => c.LastMessage?.CreatedAt ?? DateTimeOffset.MinValue).ThenBy(c => c.OtherName, StringComparer.CurrentCulture));
        return new ChatListDto(chats, chats.Sum(c => c.Unread));
    }

    /// <summary>A page of messages, oldest first. <c>after</c> returns what arrived since (for polling);
    /// <c>before</c> pages back through history. Without either, the latest page.</summary>
    [HttpGet("{key}/messages")]
    public async Task<ActionResult<IReadOnlyList<MessageDto>>> Messages(Guid familyId, string key, [FromQuery] DateTimeOffset? after,
        [FromQuery] DateTimeOffset? before, [FromQuery] int limit = 50, CancellationToken ct = default)
    {
        limit = Math.Clamp(limit, 1, MaxPage);
        var me = User.UserId();
        var members = await Members(familyId, ct);
        var thread = await FindThread(familyId, me, key, members, ct);
        if (thread is null)
        {
            return Array.Empty<MessageDto>();
        }

        var query = db.FamilyMessages.AsNoTracking().Where(m => m.ThreadId == thread.Id);
        List<FamilyMessage> page;
        if (after is { } a)
        {
            var since = a.ToUniversalTime();
            page = await query.Where(m => m.CreatedAt > since).OrderBy(m => m.CreatedAt).ThenBy(m => m.Id).Take(limit).ToListAsync(ct);
        }
        else
        {
            if (before is { } b)
            {
                var until = b.ToUniversalTime();
                query = query.Where(m => m.CreatedAt < until);
            }

            page = await query.OrderByDescending(m => m.CreatedAt).ThenByDescending(m => m.Id).Take(limit).ToListAsync(ct);
            page.Reverse();
        }

        var titles = await LinkTitles(familyId, page, ct);
        var names = members.ToDictionary(m => m.UserId, m => m.DisplayName);
        return page.Select(m => ToDto(m, names, titles)).ToList();
    }

    [HttpPost("{key}/messages")]
    [Idempotent]
    [ProducesResponseType<MessageDto>(201)]
    public async Task<IActionResult> Send(Guid familyId, string key, SendMessageRequest request, CancellationToken ct)
    {
        var me = User.UserId();
        var members = await Members(familyId, ct);
        if (request.TaskId is { } taskId && !await db.Tasks.AnyAsync(t => t.FamilyId == familyId && t.Id == taskId, ct))
        {
            throw new DomainException("message.task_not_in_family", "The task does not belong to this family.");
        }

        if (request.EventId is { } eventId && !await db.Events.AnyAsync(e => e.FamilyId == familyId && e.Id == eventId, ct))
        {
            throw new DomainException("message.event_not_in_family", "The event does not belong to this family.");
        }

        var thread = await FindThread(familyId, me, key, members, ct) ?? await CreateThread(familyId, me, key, ct);
        db.Attach(thread);
        var message = new FamilyMessage(thread, me, request.Body, request.TaskId, request.EventId, clock.GetUtcNow());
        db.FamilyMessages.Add(message);
        await db.SaveChangesAsync(ct);

        // Reload so the time is the stored (microsecond) value that read markers compare against.
        var saved = await db.FamilyMessages.AsNoTracking().FirstAsync(m => m.Id == message.Id, ct);
        await MarkRead(thread.Id, me, saved.CreatedAt, ct);

        var names = members.ToDictionary(m => m.UserId, m => m.DisplayName);
        var dto = ToDto(saved, names, await LinkTitles(familyId, [saved], ct));
        var recipients = members.Where(m => m.UserId != me && thread.Includes(m.UserId)).Select(m => m.UserId).ToList();
        await push.SendAsync(familyId, thread, names.GetValueOrDefault(me, ""), saved.Body, recipients, me, ct);
        return StatusCode(201, dto);
    }

    /// <summary>Marks everything in the chat as read for the caller.</summary>
    [HttpPost("{key}/read")]
    public async Task<IActionResult> Read(Guid familyId, string key, CancellationToken ct)
    {
        var me = User.UserId();
        var thread = await FindThread(familyId, me, key, await Members(familyId, ct), ct);
        if (thread is not null)
        {
            var latest = await db.FamilyMessages.Where(m => m.ThreadId == thread.Id).MaxAsync(m => (DateTimeOffset?)m.CreatedAt, ct);
            if (latest is { } at)
            {
                await MarkRead(thread.Id, me, at, ct);
            }
        }

        return NoContent();
    }

    private record Member(Guid UserId, string DisplayName, DateTimeOffset JoinedAt);

    private async Task<List<Member>> Members(Guid familyId, CancellationToken ct) =>
        (await db.FamilyMembers.AsNoTracking().Where(m => m.FamilyId == familyId)
            .Join(db.Users, m => m.UserId, u => u.Id, (m, u) => new { m.UserId, u.DisplayName, m.CreatedAt })
            .OrderBy(m => m.CreatedAt).ToListAsync(ct))
        .Select(m => new Member(m.UserId, m.DisplayName, m.CreatedAt)).ToList();

    /// <summary>The thread behind a key, or null when nobody has written yet. Throws 404 for a key that is not a chat of the caller.</summary>
    private async Task<MessageThread?> FindThread(Guid familyId, Guid me, string key, List<Member> members, CancellationToken ct)
    {
        var threadKey = ThreadKey(me, key, members);
        return await db.MessageThreads.AsNoTracking().FirstOrDefaultAsync(t => t.FamilyId == familyId && t.Key == threadKey, ct);
    }

    private static string ThreadKey(Guid me, string key, List<Member> members)
    {
        if (key == MessageThread.FamilyKey)
        {
            return MessageThread.FamilyKey;
        }

        if (Guid.TryParse(key, out var other) && other != me && members.Any(m => m.UserId == other))
        {
            return MessageThread.DirectKey(me, other);
        }

        throw new NotFoundException("chat.not_found", "Chat not found.");
    }

    private async Task<MessageThread> CreateThread(Guid familyId, Guid me, string key, CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        var thread = key == MessageThread.FamilyKey ? MessageThread.ForFamily(familyId, now) : MessageThread.Direct(familyId, me, Guid.Parse(key), now);
        db.MessageThreads.Add(thread);
        try
        {
            await db.SaveChangesAsync(ct);
            db.Entry(thread).State = EntityState.Detached;
            return thread;
        }
        catch (DbUpdateException ex) when (ex.InnerException is Npgsql.PostgresException { SqlState: "23505" })
        {
            // Both adults wrote the first message at the same moment: use the thread the other request created.
            db.Entry(thread).State = EntityState.Detached;
            return await db.MessageThreads.AsNoTracking().FirstAsync(t => t.FamilyId == familyId && t.Key == thread.Key, ct);
        }
    }

    private async Task MarkRead(Guid threadId, Guid userId, DateTimeOffset at, CancellationToken ct)
    {
        var state = await db.MessageReadStates.FirstOrDefaultAsync(r => r.ThreadId == threadId && r.UserId == userId, ct);
        if (state is null)
        {
            db.MessageReadStates.Add(new MessageReadState(threadId, userId, at));
        }
        else
        {
            state.MarkRead(at);
        }

        await db.SaveChangesAsync(ct);
    }

    private async Task<Dictionary<Guid, string>> LinkTitles(Guid familyId, IReadOnlyCollection<FamilyMessage> messages, CancellationToken ct)
    {
        var taskIds = messages.Where(m => m.TaskId != null).Select(m => m.TaskId!.Value).Distinct().ToList();
        var eventIds = messages.Where(m => m.EventId != null).Select(m => m.EventId!.Value).Distinct().ToList();
        var titles = new Dictionary<Guid, string>();
        if (taskIds.Count > 0)
        {
            foreach (var t in await db.Tasks.AsNoTracking().Where(t => t.FamilyId == familyId && taskIds.Contains(t.Id)).Select(t => new { t.Id, t.Title }).ToListAsync(ct))
            {
                titles[t.Id] = t.Title;
            }
        }

        if (eventIds.Count > 0)
        {
            foreach (var e in await db.Events.AsNoTracking().Where(e => e.FamilyId == familyId && eventIds.Contains(e.Id)).Select(e => new { e.Id, e.Title }).ToListAsync(ct))
            {
                titles[e.Id] = e.Title;
            }
        }

        return titles;
    }

    private static MessageDto ToDto(FamilyMessage m, Dictionary<Guid, string> names, Dictionary<Guid, string>? titles) =>
        new(m.Id, m.SenderUserId, names.GetValueOrDefault(m.SenderUserId), m.Body, m.CreatedAt, m.TaskId, m.EventId,
            (m.TaskId ?? m.EventId) is { } link && titles is not null ? titles.GetValueOrDefault(link) : null);
}
