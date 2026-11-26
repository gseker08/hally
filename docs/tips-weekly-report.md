# Akıllı ipuçları ve haftalık rapor

## Akıllı ipuçları ("Hally fark etti")

`GET /api/v1/families/{familyId}/tips` returns up to three one-line tips, worked out from the family's own data on
every read (no AI, nothing stored except dismissals). Rules (`Features/Tips/Tips.cs`):

| Kind | When | Action |
| --- | --- | --- |
| ExamStudy | an exam in 1–3 days with no study session linked to it | `startStudy` (starts homework timer for that exam) |
| ExamScreen | a child has 2+ exams in the next 7 days and no daily screen limit ≤ 60 min (parents only) | `screenLimit` sheet: 45/60/90 min, optional restore the day after the last exam |
| Vaccine | a vaccine due within 7 days, not given, nothing on the calendar that day for the child (parents or caregivers with health permission) | open health card |
| Sleep | last 3 nights average 30+ min under the age recommendation | `bedtimeEarlier` (20 min) if a bedtime routine exists, else open sleep log |
| Overdue | 3+ open tasks past due | open tasks |
| Weekend | Thu–Sat, nothing on the weekend calendar (parents only) | open screen-free activities |

Only the member's focus areas count (empty = all). Caregivers see only their children.
✕ = `POST tips/dismiss {key, forever:true}`, "Sonra" = `forever:false` (back next day). `DELETE tips/dismissed` brings hidden ones back.
A lowered screen limit is put back by the hourly `tips-screen-restore` job; setting the limit by hand cancels the pending restore.

## Haftalık rapor

`GET /api/v1/families/{familyId}/weekly-report?offset=0` (parents only; default offset is -1 on Mondays): tasks done
(+ previous week), events, exams, who did what, per child (exams + outcomes, study, average screen time, average night
sleep, cherries earned, screen-free activities), next week (exams, events, busiest day) and one tip.

The `weekly-report` job (every 15 min) sends one `WeeklyReport` notification per parent at their chosen time:
Sunday evening (default 19:00) or Monday morning. Quiet weeks get no notification. Caregivers never get it.
Settings: `GET/PUT tips/settings {enabled, reportDay: Sunday|Monday, reportTime: "HH:mm"|null}`.
App: Today tip card (`features/tips/tips.dart`), `/weekly-report`, Profile → İpuçları ve rapor (`/tips-settings`).
