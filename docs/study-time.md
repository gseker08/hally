# Homework and reading time

A hand-operated timer per child for **homework** and **reading**, with a daily **minimum** ("at least 30 minutes").
It is the opposite of the screen time goal: here reaching the goal is the good news.

## How it works

- Tap **Ödev** or **Okuma** on the child's card to start, **Bitir** to stop. The server keeps the timer, so both parents see the same running time.
- One timer per child at a time (a partial unique index on running sessions). A second Start returns the running one.
- A forgotten timer stops counting after 4 hours; the next Start closes it.
- Forgot to start it? **Süre ekle** adds finished minutes (1–240) ending now, with an optional note such as the book's name.
- **Daily goal** (5–240 minutes, homework and reading together) per child. When the day's total reaches it and no timer is running,
  every adult gets one notification for that day (`kind=StudyGoal`, opens the Homework page).
- **Streak**: days in a row the goal was met, counting back from today. An unmet today does not break it until the day is over. Looks back 60 days.
- Days are family-local calendar days.

## API

| Method | Path | Notes |
| --- | --- | --- |
| GET | `/api/v1/families/{familyId}/study` | Per child: goal, today's homework/reading seconds, running timer, streak |
| GET | `/api/v1/families/{familyId}/children/{childId}/study` | Last 7 days (oldest first, with `goalMet`) and finished entries |
| POST | `.../children/{childId}/study/start` | `{ kind: "Homework" \| "Reading" }` |
| POST | `.../children/{childId}/study/stop` | `{ note? }` |
| POST | `.../children/{childId}/study/entries` | `{ kind, minutes, note? }` |
| DELETE | `.../children/{childId}/study/{entryId}` | |
| PUT | `.../children/{childId}/study/goal` | `{ dailyMinutes }`, null removes the goal |

Every change sends `StudyChanged { familyId, childId }` over `/hubs/chat`.
