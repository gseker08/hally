# Habit streaks

Small daily habits per child, such as brushing teeth or making the bed, on chosen weekdays, with a streak.

## Rules

- A habit belongs to one child and runs on a weekday mask (Monday bit 0 … Sunday bit 6; 127 = every day).
- A parent taps the habit when it is done. Today and the 6 days before can be marked or unmarked (for a forgotten tap).
- Once per habit per family-local day (unique index), even when both parents tap.
- **Streak**: scheduled days in a row that were done, counting back from today. Unscheduled days are skipped and an unmarked
  today does not break the streak until the day is over. **Best** is the longest run. Both look back 120 days.
- Deleting a habit deletes its history.

## API

| Method | Path | Notes |
| --- | --- | --- |
| GET | `/api/v1/families/{familyId}/habits` | Today and every habit: done today, due today, streak, best, last seven days (true / false / null when not scheduled) |
| POST | `/api/v1/families/{familyId}/habits` | `{ childId, title, days? }` → 201 with the list |
| DELETE | `/api/v1/families/{familyId}/habits/{habitId}` | |
| POST | `.../habits/{habitId}/check` | `{ day? }` (default today; 422 outside the last 7 days) |
| DELETE | `.../habits/{habitId}/check?day=` | |

Every change sends `HabitsChanged { familyId }` over `/hubs/chat`.
