# Haftalık aile görevi

A shared cherry target for the week (Monday–Sunday in the family's time zone) and a reward the family earns together,
e.g. "🧺 Cumartesi piknik · 120 kiraz".

- **Who counts:** each child's cherries earned this week (chores, habits, screen-free ideas, mood answers, streak
  bonus; spending does not count) and each parent's finished tasks and school runs (2 cherries each). Caregivers are
  not part of it.
- **Nothing is taken from a child's jar:** the goal only adds up; balances stay as they are.
- **No ranking:** contributors are listed children first, then parents, in the order they joined.
- **Suggestion:** last week's total × 1.15, rounded to 10 (80 without history). The app offers it and ±40.
- **Repeat:** a goal with "Her pazartesi yeniden başlat" is copied into the new week the first time anyone opens it.
  Ending the goal (DELETE) also stops the repeat.
- **Reached:** checked when anyone opens it and by the `family-goals` job every 10 minutes; each parent gets one
  "🎉 Aile görevi tamam!" notification. Raising the target above the total opens it again.

| Endpoint | |
|---|---|
| `GET api/v1/families/{f}/goal` | parents: this week's goal (or null), last week's total, suggested target |
| `PUT api/v1/families/{f}/goal` | parents: `{rewardTitle, rewardEmoji, target 10–1000, repeat}` |
| `DELETE api/v1/families/{f}/goal` | parents: end it |
| `GET api/v1/child/goal` | child phone: the same view, shown in the jar tab |
