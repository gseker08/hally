# Child insights

Family → tap a child (the pencil still edits the child). One page with that child's logs for **a day** or **the 7 days ending
on a day**, with arrows to go back in time.

Each part shows only when it has data (or a goal):

| Part | Day view | Week view |
| --- | --- | --- |
| Screen time | Minutes, goal bar (orange when over) | Bars per day with the goal line, total, daily average, days over goal |
| Homework and reading | Homework/reading split, goal bar | Bars, days the goal was met |
| Sleep | Night and naps (a sleep counts on the day it started; days run 06:00-06:00) | Bars, nightly average |
| Feeding | Feeds, bottle ml, breast minutes, solids | Feeds per day |
| Stars | Earned, spent, balance | same for the week |
| Habits | Done/scheduled and current streak per habit | same for the week |
| Medicine | Doses per medicine | same for the week |
| Health card | Latest height/weight, allergies, overdue and upcoming vaccines, next appointment | same |
| Expenses | Spending tagged with this child | same |

Tapping a part opens its own page.

## API

`GET /api/v1/families/{familyId}/children/{childId}/insights?from=yyyy-MM-dd&to=yyyy-MM-dd` (inclusive family-local days,
default the 7 days ending today, at most 31 days; 422 `insights.range_invalid` otherwise). Returns one row per day
(`screenMinutes, homeworkMinutes, readingMinutes, nightSleepMinutes, napMinutes, feeds, bottleMl, breastMinutes, solids,
starsEarned, starsSpent, habitsDone, habitsScheduled, doses`), the goals, habits with streaks, medicines with dose counts, the star
balance, the child's expenses total and a health snapshot. Read-only; it adds no tables.
