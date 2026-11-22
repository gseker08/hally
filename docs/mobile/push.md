# Push notifications

Reminders and the evening prep summary are always written to the in-app inbox (`GET /api/v1/me/notifications`).
Push is an extra channel on top of that, sent through Firebase Cloud Messaging (FCM HTTP v1, which also reaches iOS through APNs).

## Server

| Setting | Meaning |
|---|---|
| `Push:FcmProjectId` | Firebase project id. If it is empty, pushes are only logged (no content in the log). |
| `Push:FcmServiceAccountJson` | Service account JSON with the *Firebase Cloud Messaging API* role. **Secret:** set it through the environment (`Push__FcmServiceAccountJson`) and never commit it. |

Tokens that FCM reports as unregistered are deleted automatically.

## Background jobs (Hangfire, PostgreSQL storage, schema `hangfire`)

| Job | Schedule | What it does |
|---|---|---|
| `reminders` | every minute | Sends due reminders. A reminder for a task that is done, or for a deleted item, is cancelled. Reminders more than 12 hours late are cancelled instead of sent. |
| `evening-prep` | every 15 min | At each adult's chosen hour (16–22, family time zone), sends a summary of tomorrow. Nothing is sent for an empty day. |
| `retention` | 03:30 daily | Deletes capture originals after `Storage:RetentionDays` (default 30) and keeps the extracted data. Also prunes old idempotency records, expired refresh tokens, and notifications older than 90 days. |

Every job is safe to rerun: each inbox entry has a unique dedup key. Set `Jobs:Enabled=false` to run the API without the job server, as the tests do.

## App

`lib/features/notifications/push.dart` (firebase_core + firebase_messaging):
- `PushController` starts once someone is signed in. It asks for permission (Android 13+, iOS), registers the FCM token with `PUT /api/v1/me/devices`, and registers again on every token refresh.
- Sign-out calls `DELETE /api/v1/me/devices?token=...` first, while the session is still valid.
- Tapping a push opens `pushRoute(data)`: `kind=Message` → `/chats/{chatKey}`, `targetKind=Task` → `/tasks`, `Event` → `/calendar`, else `/notifications`.
- A push that arrives while the app is open is shown as a snack bar (chat messages only refresh the badge; SignalR already shows them).
- Without Firebase config the app runs as before, just without push.

### Setting up Firebase (once)
1. Firebase console → create a project, then Project settings → Service accounts → *Generate new private key*. Put the project id and the JSON (one line) into `.env` as `FCM_PROJECT_ID` and `FCM_SERVICE_ACCOUNT_JSON`, then `docker compose up -d`.
2. Project Overview → add an Android app with package name `app.hally` and download `google-services.json` to `mobile/android/app/`. It is git-ignored because this repo is public; the Gradle build applies the google-services plugin only when the file is there. CI builds with a placeholder file.
3. iOS later: `GoogleService-Info.plist` in `ios/Runner/`, plus an APNs key in Firebase (needs the Apple Developer account).

### Testing on the emulator
Use an emulator image with Google Play services ("Google APIs" or "Google Play"). Sign in, allow notifications, then send the app to the background and let the other adult send a chat message, or create a reminder one or two minutes ahead. `docker compose logs api` shows `FCM send failed` if Firebase rejects a send.
