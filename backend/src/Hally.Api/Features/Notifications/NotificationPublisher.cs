using Hally.Domain.Common;
using Hally.Domain.Notifications;
using Hally.Domain.Users;
using Hally.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;

namespace Hally.Api.Features.Notifications;

/// <summary>Adds inbox entries to the current unit of work and pushes them after the caller has committed.
/// Push is best effort: the inbox is the source of truth.</summary>
public class NotificationPublisher(HallyDbContext db, IPushSender push, TimeProvider clock)
{
    private readonly List<Notification> _pending = [];

    /// <returns>false when this notification already exists (the job ran before), so nothing is added.</returns>
    public async Task<bool> AddAsync(Guid userId, Guid familyId, NotificationKind kind, string title, string body,
        ReminderTarget? targetKind, Guid? targetId, string dedupKey, CancellationToken ct)
    {
        if (_pending.Any(n => n.DedupKey == dedupKey) || await db.Notifications.AnyAsync(n => n.DedupKey == dedupKey, ct))
        {
            return false;
        }

        var notification = new Notification(userId, familyId, kind, title, body, targetKind, targetId, dedupKey, clock.GetUtcNow());
        db.Notifications.Add(notification);
        _pending.Add(notification);
        return true;
    }

    public async Task FlushPushAsync(CancellationToken ct)
    {
        if (_pending.Count == 0)
        {
            return;
        }

        var userIds = _pending.Select(n => n.UserId).Distinct().ToList();
        var devices = await db.Devices.Where(d => userIds.Contains(d.UserId)).ToListAsync(ct);
        var invalid = new HashSet<string>();
        foreach (var n in _pending)
        {
            var tokens = devices.Where(d => d.UserId == n.UserId).Select(d => d.Token).ToList();
            if (tokens.Count == 0)
            {
                continue;
            }

            var data = new Dictionary<string, string> { ["kind"] = n.Kind.ToString(), ["notificationId"] = n.Id.ToString(), ["familyId"] = n.FamilyId.ToString() };
            if (n.TargetId is { } target)
            {
                data["targetKind"] = n.TargetKind.ToString()!;
                data["targetId"] = target.ToString();
            }

            // A medication reminder carries a "Verdim" button, which the app draws on Android.
            var appDraws = n.Kind is NotificationKind.MedicationDue or NotificationKind.ChildAsk;
            if (n.Kind == NotificationKind.MedicationDue && n.TargetId is { } medicationId)
            {
                data["medicationId"] = medicationId.ToString();
            }

            // A child's request carries Evet/Hayır; "answered" clears it on the other parent's phone.
            if (n.Kind is NotificationKind.ChildAsk or NotificationKind.ChildAskAnswered && n.TargetId is { } askId)
            {
                data["askId"] = askId.ToString();
            }

            foreach (var token in await push.SendAsync(tokens, new PushMessage(n.Title, n.Body, data, appDraws), ct))
            {
                invalid.Add(token);
            }
        }

        _pending.Clear();
        if (invalid.Count > 0)
        {
            await db.Devices.Where(d => invalid.Contains(d.Token)).ExecuteDeleteAsync(ct);
        }
    }
}

/// <summary>Short, localized notification texts. Times are shown in the family's time zone.</summary>
public static class NotificationTexts
{
    public static (string Title, string Body) Reminder(string locale, string title, DateTimeOffset? at, bool allDay, DateTimeOffset localNow)
    {
        if (at is not { } when)
        {
            return (title, Texts.Get(locale, "reminder.taskOpen"));
        }

        var day = DateOnly.FromDateTime(when.DateTime);
        var today = DateOnly.FromDateTime(localNow.DateTime);
        var dayText = day == today ? Texts.Get(locale, "day.today")
            : day == today.AddDays(1) ? Texts.Get(locale, "day.tomorrow")
            : when.ToString(Texts.Get(locale, "format.shortDate"), Texts.Culture(locale));
        return (title, allDay ? dayText : $"{dayText} {when:HH:mm}");
    }

    public static (string Title, string Body) EveningPrep(string locale, int taskCount, int eventCount, IReadOnlyList<string> highlights)
    {
        var counts = string.Join(", ", new[]
        {
            eventCount > 0 ? Texts.Plural(locale, "count.events", eventCount) : null,
            taskCount > 0 ? Texts.Plural(locale, "count.tasks", taskCount) : null,
        }.OfType<string>());
        var body = highlights.Count == 0 ? counts : $"{counts}: {string.Join(" · ", highlights)}";
        return (Texts.Get(locale, "evening.title"), body);
    }
}
