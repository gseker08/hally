using Hally.Domain.Common;

namespace Hally.Domain.Messaging;

public enum MessageThreadKind
{
    /// <summary>One per family: every adult member reads and writes it.</summary>
    Family,

    /// <summary>Between exactly two adults of the same family.</summary>
    Direct,
}

/// <summary>A conversation between the adults of a family. Created on first use.</summary>
public class MessageThread : Entity
{
    public const string FamilyKey = "family";

    private MessageThread() { }

    private MessageThread(Guid familyId, MessageThreadKind kind, string key, Guid? userA, Guid? userB, DateTimeOffset now)
    {
        FamilyId = familyId;
        Kind = kind;
        Key = key;
        UserA = userA;
        UserB = userB;
        CreatedAt = now;
    }

    public static MessageThread ForFamily(Guid familyId, DateTimeOffset now) =>
        new(familyId, MessageThreadKind.Family, FamilyKey, null, null, now);

    public static MessageThread Direct(Guid familyId, Guid one, Guid other, DateTimeOffset now)
    {
        if (one == other)
        {
            throw new DomainException("messages.self_chat", "A direct chat needs two different people.");
        }

        var (a, b) = one.CompareTo(other) < 0 ? (one, other) : (other, one);
        return new(familyId, MessageThreadKind.Direct, DirectKey(one, other), a, b, now);
    }

    /// <summary>Stable key of the direct chat between two users, whatever the order.</summary>
    public static string DirectKey(Guid one, Guid other)
    {
        var (a, b) = one.CompareTo(other) < 0 ? (one, other) : (other, one);
        return $"{a:N}:{b:N}";
    }

    public Guid FamilyId { get; private set; }
    public MessageThreadKind Kind { get; private set; }

    /// <summary>"family", or the two user ids for a direct chat. Unique per family.</summary>
    public string Key { get; private set; } = default!;

    public Guid? UserA { get; private set; }
    public Guid? UserB { get; private set; }
    public DateTimeOffset? LastMessageAt { get; private set; }

    public bool Includes(Guid userId) => Kind == MessageThreadKind.Family || UserA == userId || UserB == userId;

    public void Touch(DateTimeOffset at) => LastMessageAt = at;
}

/// <summary>A text message in a family or direct chat, optionally pointing at a task or event.</summary>
public class FamilyMessage : Entity
{
    public const int MaxLength = 2000;

    private FamilyMessage() { }

    public FamilyMessage(MessageThread thread, Guid senderUserId, string body, Guid? taskId, Guid? eventId, DateTimeOffset now)
    {
        if (string.IsNullOrWhiteSpace(body) || body.Trim().Length > MaxLength)
        {
            throw new DomainException("message.body_invalid", $"A message must be 1-{MaxLength} characters.");
        }

        if (taskId is not null && eventId is not null)
        {
            throw new DomainException("message.one_link", "A message can point at a task or an event, not both.");
        }

        ThreadId = thread.Id;
        FamilyId = thread.FamilyId;
        SenderUserId = senderUserId;
        Body = body.Trim();
        TaskId = taskId;
        EventId = eventId;
        CreatedAt = now;
        thread.Touch(now);
    }

    public Guid ThreadId { get; private set; }
    public Guid FamilyId { get; private set; }
    public Guid SenderUserId { get; private set; }
    public string Body { get; private set; } = default!;
    public Guid? TaskId { get; private set; }
    public Guid? EventId { get; private set; }
}

/// <summary>How far a user has read a thread. Messages after <see cref="LastReadAt"/> from others are unread.</summary>
public class MessageReadState
{
    private MessageReadState() { }

    public MessageReadState(Guid threadId, Guid userId, DateTimeOffset at)
    {
        ThreadId = threadId;
        UserId = userId;
        LastReadAt = at;
    }

    public Guid ThreadId { get; private set; }
    public Guid UserId { get; private set; }
    public DateTimeOffset LastReadAt { get; private set; }

    public void MarkRead(DateTimeOffset at)
    {
        if (at > LastReadAt)
        {
            LastReadAt = at;
        }
    }
}
