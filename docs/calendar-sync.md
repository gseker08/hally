# Calendar sync (Google, iCloud, Outlook)

Hally syncs through the **phone's own calendars** (Android Calendar Provider, iOS EventKit) using
[`device_calendar_plus`](https://pub.dev/packages/device_calendar_plus). Any Google, iCloud or Outlook/Exchange
account that is set up on the phone shows up there, so Hally needs no passwords and no Google/Microsoft OAuth
(which would need Google's OAuth app verification for calendar scopes, Azure publisher verification, and
app-specific passwords + CalDAV for iCloud). Direct OAuth can still be added later.

## What syncs

| Direction | How | Where it lives |
| --- | --- | --- |
| Phone calendar → Hally, **"Sadece ben"** | Read live from the phone when the Calendar tab shows a range | Never leaves the phone |
| Phone calendar → family, **"Ailem"** | App sends the full set for −7…+90 days to `PUT /families/{id}/external-events`; the server replaces the parent's set | `external_events` (read-only copies; title is null when "busy only") |
| Hally → phone | App writes each Hally event occurrence into a separate local **"Hally"** calendar, diffing by `eventId|start` + fingerprint | Phone |
| Hally → computer | Private iCal link `GET /ics/{token}.ics` (one per parent and family; only the SHA-256 of the token is stored; `POST` makes a new one and kills the old) | Server renders on request, −30…+365 days, series expanded |

Sync runs when the app starts or comes back to the foreground (at most every 5 minutes), when the parent saves the
connect screen, and on pull-to-refresh in Profile → Bağlı takvimler. Settings are kept on the device
(`hally.calendar_sync` in secure storage), not on the server.

Rules:
- Parents only. Caregivers neither see parents' shared events nor get the feature (`ExternalEventsController` and
  `CalendarFeedController` are not `[CaregiverAllowed]`).
- Shared events show only under the "Hepsi" child filter, read-only, with a source pill; tapping one of your own
  opens it in the phone's calendar app.
- The "Hally" calendar is never read back (no loops), and the iCal feed never includes shared phone events.
- Leaving the family or deleting the account removes the parent's shared events and feed (`AccountService`); the
  feed also stops answering once the parent is no longer a parent in the family.

## Store and privacy

- Android: `READ_CALENDAR` / `WRITE_CALENDAR` (normal runtime permissions, no Play declaration form). Play Console
  **Data safety** must list *Calendar events* (collected, shared with family members only, optional).
- iOS: `NSCalendarsFullAccessUsageDescription` + `NSCalendarsUsageDescription` (Info.plist and every `*.lproj`).
- Privacy policy (`site/gizlilik.html`, `site/privacy.html`), KVKK text and the in-app privacy screen mention it.

Code: `mobile/lib/features/calendar_sync/`, `backend/src/Hally.Api/Features/CalendarSync/`,
`Hally.Domain/Planning/ExternalEvent.cs`. Design: `/mnt/project-files/hally/design/takvim-senkron/`.
