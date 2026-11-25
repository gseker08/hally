using Hally.Domain.Common;

namespace Hally.Domain.Care;

/// <summary>Something that happened while the caregiver looked after the child. Shown orange to parents, never red.</summary>
public enum HandoffIncident
{
    Fall,
    Fever,
    Other,
}

/// <summary>
/// A caregiver's end-of-day report for one child ("Günü bitir"): a snapshot of what was logged that day (food, sleep,
/// medicine, screen time) plus incidents, a note and an optional photo. One per child, day and author; sending again
/// replaces the earlier report.
/// </summary>
public class HandoffReport : Entity
{
    public const int MaxNote = 500;

    private HandoffReport() { }

    public HandoffReport(Guid familyId, Guid childId, Guid byUserId, DateOnly day, DateTimeOffset now)
    {
        FamilyId = familyId;
        ChildId = childId;
        ByUserId = byUserId;
        Day = day;
        CreatedAt = now;
        SentAt = now;
    }

    public Guid FamilyId { get; private set; }
    public Guid ChildId { get; private set; }
    public Guid ByUserId { get; private set; }
    public DateOnly Day { get; private set; }

    /// <summary>The day's logs at the moment of sending, as JSON (see the API's HandoffSummaryDto).</summary>
    public string SummaryJson { get; private set; } = "{}";

    public List<HandoffIncident> Incidents { get; private set; } = [];
    public string? Note { get; private set; }
    public string? PhotoKey { get; private set; }
    public string? PhotoContentType { get; private set; }
    public DateTimeOffset SentAt { get; private set; }
    public DateTimeOffset? ThankedAt { get; private set; }
    public Guid? ThankedByUserId { get; private set; }

    public void Fill(string summaryJson, IEnumerable<HandoffIncident> incidents, string? note, DateTimeOffset now)
    {
        note = string.IsNullOrWhiteSpace(note) ? null : note.Trim();
        if (note?.Length > MaxNote)
        {
            throw new DomainException("handoff.note_too_long", $"The note can be up to {MaxNote} characters.");
        }

        SummaryJson = summaryJson;
        Incidents = incidents.Distinct().OrderBy(i => i).ToList();
        Note = note;
        SentAt = now;
        ThankedAt = null;
        ThankedByUserId = null;
    }

    /// <summary>Returns the previous photo's storage key, if any, so the caller can delete it.</summary>
    public string? SetPhoto(string key, string contentType)
    {
        var old = PhotoKey;
        PhotoKey = key;
        PhotoContentType = contentType;
        return old;
    }

    public void Thank(Guid userId, DateTimeOffset now)
    {
        ThankedAt ??= now;
        ThankedByUserId ??= userId;
    }
}
