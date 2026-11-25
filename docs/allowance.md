# Harçlık ve birikim hedefi (pocket money and savings goal)

Cherries can turn into pocket money with a parent's OK, and the child can save toward a goal ("Bisiklet · 300 kiraz").
Hally never holds or moves money; it only records what the parents say they paid.

## Child (Kavanoz tab)

- **Birikimim:** the goal (emoji, name, cherries), a progress bar against the jar balance, and an estimate:
  "Böyle devam edersen N hafta sonra". The estimate divides the cherries gained in the last 28 days by 4 (earned plus
  weekly allowance; spending is left out). There is no estimate with no cherries lately.
- **Harçlığa çevir:** "10 kiraz = 5 ₺ · annen ya da baban onaylar". The child picks an amount in whole steps (up to
  the jar), then "Annemle babama sor". One request can wait at a time. Nothing leaves the jar until a parent pays.
- **Son hareketler:** the last 10 ledger lines.

## Parents

- **Where:** Çocuklar → child → 💰 (or the child-phone screen → Harçlık). Route: `/allowance/:childId?familyId=&name=`.
  - Kiraz değeri: default 10 = 5 ₺.
  - Haftalık harçlık in cherries (Yok/10/20/30). The hourly `weekly-allowance` job adds it once per family-local
    Monday (`AllowancePlan.WeeklyPaidFor`).
  - "Harcamalar'a yaz" switch.
  - Waiting and past requests, and the child's goal.
- **Today:** waiting requests appear with **Ödedim** / **Şimdi değil**.
- **Ödedim:**
  - adds a `PointKind.Allowance` line of minus the cherries, re-checking the balance (`points.not_enough`)
  - if the switch is on, adds an Expense "Harçlık · Ela" (category Other, shared by the parents)
  - Status is a concurrency token, so a second answer gets 422 `allowance.already_decided`.
- **Notifications:** parents get `NotificationKind.AllowanceRequest` ("Ela harçlık istiyor · 40 kiraz = 20 ₺"). It opens the
  Harçlık page.
- **Caregivers** don't see anything about money.

## Ledger

`PointKind.Allowance` (weekly `+` / converted `−`) is not "earned":

- it doesn't count for the streak
- it doesn't count for the child's "this week" total
- it doesn't count for the weekly family goal

## API

| | |
|---|---|
| `GET /api/v1/child/savings` | balance, goal, weeksToGoal, settings, pending, recent |
| `PUT/DELETE /api/v1/child/savings/goal` | `{title, emoji, cherries}` (10–10000) |
| `POST /api/v1/child/savings/convert` | `{cherries}`: whole steps; one waiting at a time |
| `GET/PUT /api/v1/families/{f}/children/{c}/allowance` | settings, goal, balance, requests |
| `GET /api/v1/families/{f}/allowance-requests` | waiting requests (Today) |
| `POST /api/v1/families/{f}/allowance-requests/{id}/decide` | `{paid}` |
