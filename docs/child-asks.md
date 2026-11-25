# Bir şey iste (child requests)

A child in child mode can ask the parents for something from their own phone: "Arkadaşıma gidebilir miyim?",
"15 dk daha oyun". Every parent gets a notification with **Evet / Hayır**; the first answer counts and the child sees
it (with an optional note) right away.

## Child

- Bugünüm shows a "Bir şey iste" card with the latest request and its status.
- The page lists the family's ready-made requests plus "Kendim yazayım…" (free text, max 60).
- A request with a follow-up question ("Kimin evine?") opens a sheet with quick answers and "＋ Yaz".
- Limits: the same request can't be sent again while it waits (422 `ask.already_pending`); at most 3 open and 20 per
  day (`ask.too_many`).
- The child's phone has no push, so the page checks for answers every 10 s while something waits. The lock screen's
  "15 dk daha iste" is a request too; after asking, the lock screen refreshes every 15 s and opens by itself on a yes.

## Parents

- Android: the push is data-only (`kind=ChildAsk`, `askId`) and the app draws it with Evet/Hayır buttons that answer
  in the background, also with the app closed. iPhone: APNs category `hally.ask`; AppDelegate runs the answer through
  the background Dart engine (`hally://ask/answer?family=&ask=&yes=1|0`).
- "Yanıtla" = tap the notification: `/asks` opens with a note field. Open requests also show on Today.
- First answer wins (`ExecuteUpdate … where Status = Pending`). The second gets 409 `ask.already_answered`; from the
  lock screen that becomes "İstek zaten yanıtlandı". The other parents get `ChildAskAnswered` ("Ayşe onayladı"),
  which also removes their Evet/Hayır notification (same collapse id on iOS).
- A yes on a request with `ScreenMinutes` adds a `ScreenBonus`, so the lock really moves.
- Caregivers don't see or answer requests.
- Ready-made list: `/ask-presets` (also from the child's phone page). Up to 8, each with emoji, title, optional
  follow-up question with up to 6 quick answers, optional extra screen minutes. Defaults are created on first use;
  a list the parents emptied stays empty (`Family.AskPresetsEdited`).

## API

| | |
|---|---|
| `GET /api/v1/child/asks?lang` | presets + today's requests |
| `POST /api/v1/child/asks?lang` | `{presetId, detail}` or `{text}` |
| `POST /api/v1/child/screen/request` | lock screen "15 dk daha iste" → request with minutes |
| `GET /api/v1/families/{f}/asks` | today's + still open (parents) |
| `POST /api/v1/families/{f}/asks/{id}/answer` | `{yes, note}` |
| `GET/PUT /api/v1/families/{f}/ask-presets` | the ready-made list |

Requests from an earlier day that nobody answered show as `Expired` and can't be answered. Requests are deleted
after 90 days (RetentionJob).
