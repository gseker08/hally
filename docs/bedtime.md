# Uyku öncesi rutini

Parents set a child's evening routine (`PUT families/{f}/children/{c}/bedtime`):
- the time (17:00–04:59)
- 1–8 ordered steps (title + emoji)
- cherries (0–10, default 3)
- "lock until morning" (default on)
- on/off

## Child's phone

- `GET child/home` and `GET child/bedtime` carry tonight: the steps, how many are done, and whether it is open.
- **Open** runs from 30 minutes before the time until 07:00. Before noon, a moment still belongs to the previous evening, so 01:30 on Tuesday is Monday's night.
- While the routine is open and not finished, the app opens the night-themed steps screen by itself whenever it is opened or comes back to the foreground. A card on Bugünüm reopens it after "Sonra".
- `POST child/bedtime/steps/{i}/done` checks the steps strictly in order (422 `bedtime.out_of_order`). Repeating a step that is already done changes nothing.
- **The last step:**
  - adds the cherries once (`PointKind.Bedtime`)
  - sends each parent "🌙 Ela yatağında · Uyku rutini bitti · 20:42"
  - shows the story/breathing screen. A short built-in story is read aloud with the phone's text-to-speech (Turkish voice), then the screen dims.
- **Night lock:** with "lock until morning" on, `ChildScreenDto.Locked` (and the new `Bedtime` flag) stays true from the finished routine until 07:00. The Android lock covers the phone, and the app shows the night screen instead of "Ekran süren doldu". Extra minutes do not lift it.

Bedtime evenings older than 90 days are deleted by the retention job.

The child's phone has no push of its own, so "opens by itself at the time" means it opens the next time the app comes to the foreground in the window.
