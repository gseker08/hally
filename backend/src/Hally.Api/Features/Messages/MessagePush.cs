using Hally.Api.Features.Notifications;
using Hally.Domain.Messaging;
using Hally.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.Messages;

/// <summary>Pushes a new chat message to the recipients' devices. No inbox entry: the chat list has its own unread count.
/// Best effort, like every push: a failure never fails the send.</summary>
public class MessagePush(HallyDbContext db, IPushSender push, ILogger<MessagePush> logger)
{
    public const int PreviewLength = 140;

    public async Task SendAsync(Guid familyId, MessageThread thread, string senderName, string body, bool hasPhoto, IReadOnlyCollection<Guid> recipients,
        Guid senderId, CancellationToken ct)
    {
        if (recipients.Count == 0)
        {
            return;
        }

        try
        {
            var users = await db.Users.AsNoTracking().Where(u => recipients.Contains(u.Id)).Select(u => new { u.Id, u.Locale }).ToListAsync(ct);
            var devices = await db.Devices.AsNoTracking().Where(d => recipients.Contains(d.UserId)).ToListAsync(ct);
            var text = body.Length > PreviewLength ? body[..PreviewLength] + "…" : body;
            var first = senderName.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? senderName;
            var invalid = new List<string>();
            foreach (var user in users)
            {
                var tokens = devices.Where(d => d.UserId == user.Id).Select(d => d.Token).ToList();
                if (tokens.Count == 0)
                {
                    continue;
                }

                var photo = user.Locale == "en" ? "📷 Photo" : "📷 Fotoğraf";
                var preview = !hasPhoto ? text : text.Length == 0 ? photo : $"📷 {text}";
                var title = thread.Kind == MessageThreadKind.Family
                    ? $"{first} · {(user.Locale == "en" ? "Family chat" : "Aile sohbeti")}"
                    : first;
                // The recipient opens the chat by its own key: the family chat, or the sender's id for a direct chat.
                var chatKey = thread.Kind == MessageThreadKind.Family ? MessageThread.FamilyKey : senderId.ToString();
                var data = new Dictionary<string, string> { ["kind"] = "Message", ["familyId"] = familyId.ToString(), ["chatKey"] = chatKey };
                invalid.AddRange(await push.SendAsync(tokens, new PushMessage(title, preview, data), ct));
            }

            if (invalid.Count > 0)
            {
                await db.Devices.Where(d => invalid.Contains(d.Token)).ExecuteDeleteAsync(ct);
            }
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "Message push failed");
        }
    }
}
