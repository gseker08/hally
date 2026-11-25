# Child mode (server)

A child's own phone runs Hally in child mode. There is no child account: a parent pairs the phone with a one-time code.

## Pairing

1. A parent: `POST /api/v1/families/{f}/children/{c}/pairing-code` → six digits, valid 10 minutes, once. A new code replaces the child's unused one.
2. The child's phone: `POST /api/v1/child/pair { code, deviceName }` (anonymous, rate limited per address: `ChildMode:PairAttemptsPer10Minutes`, default 10) → a device token, shown once; only its SHA-256 is stored (`child_devices`).
3. The phone sends the token in the `X-Hally-Child` header. This is its own authentication scheme (`ChildDeviceAuth`). The default JWT scheme never reads it, so a child phone cannot reach any parent endpoint, and a parent token cannot reach `/api/v1/child`. Each request checks the database, so unpairing (`DELETE .../children/{c}/devices/{id}`) works at once.

## Cherries

Cherries are the existing chore-points ledger (`point_entries`), shown as cherries in the app.

- The child marks a chore or habit done: `POST /api/v1/child/chores/{id}/done`, `.../habits/{id}/done`.
- With `families.require_child_approval` on (the default, `PUT /families/{f}/child-mode`), this creates a pending `child_claims` row and notifies the parents (not caregivers). A parent approves or rejects it: `POST /families/{f}/claims/{id}/approve|reject`. A rejected one can be tried again the same day.
- Approved: a chore adds its points, a habit adds one cherry and ticks the habit for the parents too. Something a parent already ticked is not counted twice.
- Streak: days in a row with cherries earned. Every 7th day adds a bonus of 5 (`PointKind.Bonus`, once per day).
- Rewards: `POST /api/v1/child/rewards/{id}/redeem` spends cherries. A reward with `ScreenMinutes` adds that much screen time for today at once; for any reward the parents get a note.

## Screen time on the child's phone

- The phone measures its own use and reports today's running total: `POST /api/v1/child/screen { usedSeconds }`. The stored value only grows.
- The answer has `GoalMinutes` (the child's daily limit, null = no limit), `BonusMinutes`, `LimitMinutes`, `UsedSeconds`, `Locked`. The phone locks when `Locked` is true (Android lock comes in its own PR).
- The first report over the limit notifies the parents. The child can ask for more: `POST /api/v1/child/screen/request { minutes }` (one note per 10 minutes).
- Parents give extra minutes for today: `POST /families/{f}/children/{c}/screen-bonus { minutes }` and see the phone's numbers at `GET .../device-screen`.

## Child home

`GET /api/v1/child/home`: the child's name and color, balance, this week's cherries, streak and days to the next bonus, today's chores and scheduled habits (Todo / Pending / Done), rewards and screen status.

## Privacy

The child's phone stores only the device token. The server keeps the device name the parent sees and the last time it was seen. Unpairing or deleting the child removes access.
