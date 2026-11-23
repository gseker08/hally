using Hally.Api.Common;
using Hally.Domain.Messaging;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.SignalR;

namespace Hally.Api.Features.Messages;

/// <summary>A new message, as seen by one recipient: <c>ChatKey</c> is the key that recipient uses for the chat
/// ("family", or the other adult's id).</summary>
public record ChatMessageEvent(Guid FamilyId, string ChatKey, MessageDto Message);

/// <summary>Methods the server calls on connected apps (strongly typed, so a typo is a compile error).</summary>
public interface IChatClient
{
    Task MessageReceived(ChatMessageEvent e);

    /// <summary>A child's screen time timer started, stopped or changed (see ScreenTime feature).</summary>
    Task ScreenTimeChanged(ScreenTime.ScreenTimeEvent e);

    /// <summary>A medication or one of its doses changed; apps reload the medication list.</summary>
    Task MedicationChanged(Medications.MedicationEvent e);

    /// <summary>The family's shopping list changed; apps reload it.</summary>
    Task ShoppingChanged(Shopping.ShoppingEvent e);

    /// <summary>A child fell asleep, woke up, or a sleep was added or removed; apps reload.</summary>
    Task SleepChanged(Sleep.SleepEvent e);
}

/// <summary>
/// Live channel at <c>/hubs/chat</c> for chat messages and other family events (screen time, medications, shopping list, sleep). Apps only listen: sending still goes through the REST API,
/// which validates, stores and then announces the message here. Every connection joins its user's group, so all
/// of a person's devices get the event. The JWT comes in the <c>access_token</c> query string (WebSockets cannot
/// send headers from browsers and most mobile clients), see Program.cs.
/// </summary>
[Authorize]
public class ChatHub : Hub<IChatClient>
{
    public const string Path = "/hubs/chat";

    public static string UserGroup(Guid userId) => $"user:{userId:N}";

    public override async Task OnConnectedAsync()
    {
        await Groups.AddToGroupAsync(Context.ConnectionId, UserGroup(Context.User!.UserId()));
        await base.OnConnectedAsync();
    }
}

/// <summary>Announces stored messages to the connected apps of everyone in the chat, the sender's other devices included.
/// Best effort: an app that is offline catches up through the REST API (and push).</summary>
public class ChatRealtime(IHubContext<ChatHub, IChatClient> hub, ILogger<ChatRealtime> logger)
{
    public async Task MessageSentAsync(Guid familyId, MessageThread thread, MessageDto message, IEnumerable<Guid> participants)
    {
        try
        {
            foreach (var userId in participants)
            {
                var key = thread.Kind == MessageThreadKind.Family
                    ? MessageThread.FamilyKey
                    : (thread.UserA == userId ? thread.UserB : thread.UserA).ToString()!;
                await hub.Clients.Group(ChatHub.UserGroup(userId)).MessageReceived(new ChatMessageEvent(familyId, key, message));
            }
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Realtime chat event failed");
        }
    }
}
