# Yük dengesi (load balance)

"Bu hafta kim ne yaptı?" — Aile → Yük dengesi (`/balance`). Parents only; caregivers are listed but cannot open it.

`GET /api/v1/families/{familyId}/balance?from=&to=` (inclusive family-local days, default Monday → today, max 31 days).

Per current family member it counts what they marked done in Hally in the range:

| Column | Source |
| --- | --- |
| `tasks` | `FamilyTask.CompletedByUserId` / `CompletedAt` |
| `schoolRuns` | `DutyDone.ByUserId` / `Date` |
| `feedings` | `FeedingEntry.ByUserId` / `At` |
| `shopping` | `ShoppingItem.CheckedByUserId` / `CheckedAt` |
| `medications` | `MedicationDose.GivenByUserId` / `GivenAt` |

`suggestion` appears only for a range ending today, with at least two parents, at least 6 things done, and a parent
doing more than 40%. It names the parent who did least and the heavy parent's next planned school run in the coming
7 days (or none). The app shows the "Mesajla sor" button only to the heavy parent; it opens the direct chat with a
pre-written draft, nothing is sent or reassigned automatically.
