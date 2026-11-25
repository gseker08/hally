# Çocuğun duygu kontrolü (child mood check-in)

Child mode asks "Bugün nasılsın?" once a day on the Bugünüm tab (skippable with "Sonra"). Six faces (Great, Good,
Okay, Sad, Angry, Tired) and optional reasons (Friends, School, Home, Play). Any answer earns the same +1 cherry
(`PointKind.Mood`, once a day) so honesty is never worth less. Answering again the same day changes the answer only.

- Child phone: `POST /api/v1/child/mood { mood, reasons }` → `{ mood, cherries }`; `ChildHomeDto.TodayMood`.
- Parents only: `GET /api/v1/families/{f}/children/{c}/moods?from&to` (≤ 28 days) → days, most common mood, top
  reason and a `nudge` for the latest Sad/Angry day in the last 3 days. Caregivers get 403. App: Çocuklar → child →
  Duygular (`/child/:id/moods`).
- Retention: `RetentionJob` deletes answers older than 90 days. Privacy texts (site/gizlilik, kvkk, privacy) updated.
- Not a medical assessment; the nudge is a conversation idea, never a push or alarm.
