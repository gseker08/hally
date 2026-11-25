# Spoken day summary ("Bugün ne var?")

A parent asks "Bugün ne var?" or "Yarın ne var?" (typed, spoken with the mic, or with the 🔊 chip on the assistant screen) and Hally reads the day aloud with the phone's own voice. The summary is built on the server from the family's own data; **no AI and no AI key or AI consent is needed** (the mic still asks for the AI consent, because other spoken questions go to the AI).

## API
- `GET /api/v1/families/{f}/briefing?day=today|tomorrow&lang=tr|en` (parents and caregivers; caregivers only see what their scope allows, medicines only with health access) returns `greeting`, `lines[{kind, emoji, text}]`, `speech` (no emoji, for TTS) and `shortSpeech` ("Daha kısa").
- Sources: events (`EventsInRangeAsync`, recurring expanded), school run (the day's override, else the weekday rule), open tasks due that day (plus overdue ones for today), medicines whose next dose is that day, and the current weather (today only, when the family set a place).
- `GET/PUT /api/v1/families/{f}/briefing/settings` `{ "time": "07:30" | null }` per member; 05:00–11:30 or 422 `briefing.time_invalid`.

## Morning notification
Hangfire job `morning-briefing` runs every 5 minutes and sends `NotificationKind.MorningBriefing` ("☀️ Günaydın! Bugünün özeti", first two lines as the body) within 30 minutes after the chosen time in the family's time zone, once a day (`FamilyMember.BriefingSentOn`). Tapping it opens `/assistant?briefing=1`, which plays today's summary.

## App
- `lib/features/assistant/briefing.dart`: models, `briefingDayOf` (which messages skip the AI), repository, `briefingSpeakerProvider` (flutter_tts, rate 0.5).
- `AssistantScreen`: briefing bubble with Durdur / Tekrar oku / Daha kısa; the ☀️ app bar button sets the morning time.
