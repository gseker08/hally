# Feeding log

Either parent logs a feed for a child in two taps: **breast** (side and minutes), **bottle** (ml) or **solids** (what was eaten).
The Feeding page answers the two questions asked at 3 AM: *when did she last eat?* and *which side is next?*

## Rules

- A feed can be up to 5 minutes in the future (clock drift) and up to 14 days in the past.
- Breast needs a side (Left, Right, Both), 1–120 minutes. Bottle needs 5–500 ml. Solids need a food (up to 80 characters).
- **Next side**: after Left comes Right and after Right comes Left; after Both, Hally does not guess. Bottles and solids do not change it.
- Days are family-local calendar days (midnight to midnight, in the family's time zone).
- Hally never gives feeding advice or amounts; it only records what parents enter.

## API

| Method | Path | Notes |
| --- | --- | --- |
| GET | `/api/v1/families/{familyId}/feeding` | Per child: last feed, next side, feeds today, bottle ml today |
| GET | `/api/v1/families/{familyId}/children/{childId}/feeding?days=3` | Day totals (oldest first, 1–14 days) and feeds (newest first) |
| POST | `/api/v1/families/{familyId}/children/{childId}/feeding` | `{ kind, at?, side?, minutes?, amountMl?, food?, note? }` → 201 with the child's status; 422 on a missing field or a future time |
| DELETE | `/api/v1/families/{familyId}/children/{childId}/feeding/{entryId}` | Returns the child's status |

Every change sends `FeedingChanged { familyId, childId }` over `/hubs/chat` to the family's adults, so the other parent's phone updates at once.
Without a live connection the app reloads once a minute.
