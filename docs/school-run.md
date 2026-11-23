# School run duty

Who takes the children to school (**drop-off**) and who brings them home (**pick-up**): a usual plan per weekday, changes
for single dates, and a "done" tap that tells the other adults.

## Rules

- A slot is done by a family adult (`assigneeUserId`) or by someone outside the app, by name ("Babaanne", "Servis"), with an optional time.
- The **usual plan** is per weekday (0 Monday … 6 Sunday). A **change** for one date wins over it; a change with nobody means
  "not needed" that day (a holiday). Changes can be set from a week ago to four months ahead; deleting one goes back to the usual plan.
- **Done**: "Bıraktım" / "Aldım" for today, once per slot per family-local day. The other adults get a push
  (`kind=DutyDone`: "Okula bırakıldı · Ayşe çocukları okula bıraktı.") that opens the School run page. Undo removes the mark, not the push.
- Times travel as `HH:mm:ss`.

## API

| Method | Path | Notes |
| --- | --- | --- |
| GET | `/api/v1/families/{familyId}/duties?start=` | A week from Monday: per day drop-off and pick-up (who, time, change, done), the usual plan, the adults |
| PUT | `.../duties/rules/{weekday}/{DropOff\|PickUp}` | `{ assigneeUserId?, assigneeName?, time? }`; both empty removes the rule |
| PUT | `.../duties/{date}/{kind}` | Change for a date; both empty means not needed |
| DELETE | `.../duties/{date}/{kind}` | Back to the usual plan |
| POST / DELETE | `.../duties/today/{kind}/done` | Done tap and undo |

Every change sends `DutiesChanged { familyId }` over `/hubs/chat`.
