# Realtime chat (SignalR)

Chat messages are stored through the REST API and then announced over SignalR, so open apps update at once.

```
App A ──POST /chats/{key}/messages──▶ MessagesController ──save──▶ PostgreSQL
                                           │
                                           ├─▶ ChatRealtime ──▶ ChatHub group "user:{id}" ──▶ App B (and A's other devices)
                                           └─▶ MessagePush ──▶ FCM (when configured)
```

## Server

- `Features/Messages/ChatHub.cs`: `ChatHub : Hub<IChatClient>` at `/hubs/chat`, `[Authorize]`. On connect a connection
  joins the group `user:{userId}`. Groups per *user* (not per chat) mean one connection serves every chat and every
  family of that user, and a new chat needs no subscription.
- Clients only listen. Sending stays on REST, so validation, idempotency, storage and push live in one place and a
  dropped socket never loses a message.
- `ChatRealtime.MessageSentAsync` sends `MessageReceived(ChatMessageEvent)` to each participant with *their* chat
  key (`family`, or the other adult's id).
- Auth: WebSocket clients cannot send headers, so `Program.cs` reads `access_token` from the query string for
  `/hubs/*` only. Serilog request logging records the path without the query string.
- Scale-out: with more than one API instance, add a backplane (Redis: `AddStackExchangeRedis`) so a message stored on
  one instance reaches connections on another.

## App

- `lib/features/messages/chat_realtime.dart`: `SignalRChatRealtime` wraps `signalr_netcore` (the Dart port of the
  .NET client). Automatic reconnect covers short drops; after that it retries every 30 s. Before connecting it lets
  the API client refresh an access token that is about to expire.
- `chatRealtimeProvider` holds one connection per signed-in user (`NoChatRealtime` when signed out and in tests).
- Chat screen: appends live messages for its key and marks them read. While connected it polls only every 30 s as a
  safety net; offline it polls every 5 s like before. The chat list and the unread badge refresh on every event.

## Trying it locally

1. `git pull`, then `docker compose up -d --build` (the API serves `/hubs/chat` on the same port).
2. Run the app on the emulator signed in as one adult, and as the other adult on a second emulator or a device.
3. Open the same chat on both and send a message: it appears on the other side without waiting.
4. To watch the socket: `docker compose logs -f api` shows `/hubs/chat/negotiate` and the WebSocket request.

## Tests

- `backend/tests/Hally.Api.Tests/ChatHubTests.cs` connects real `HubConnection`s (long polling through the test
  server) and checks that both adults get the event with their own chat key, a stranger gets nothing, and a
  connection without a token is refused.
- `mobile/test/messages_test.dart` drives the chat screen with a fake `ChatRealtime`.

## Photos in chats

- Send: `POST /api/v1/families/{familyId}/chats/{key}/photos` (multipart: `file`, optional `caption`), idempotent like
  text messages. JPEG, PNG, WebP or HEIC up to 10 MB. The server checks the file's first bytes, not the declared type,
  because it serves the photo back with that type.
- The photo is stored with the same AES-GCM `IDocumentStore` as captures, under the family's folder. Unlike capture
  originals it is not removed by the retention job: it is part of the chat.
- Read: `GET .../chats/{key}/messages/{messageId}/photo`. The key must be the caller's key for that chat, so only the
  people in it can read it. `Cache-Control: private, immutable`, `nosniff`.
- `MessageDto.hasPhoto` marks such messages; `body` is the caption and may be empty. Live delivery (`MessageReceived`)
  and push are the same as for text; the push text is "📷 Fotoğraf" or "📷 caption".
- Deletion: direct-chat photos go when one of the two adults leaves, a person's photos go when their account is
  deleted, and all photos go with the family.
- App: `chat_photo.dart` picks from camera or gallery (shrunk to 1600 px, quality 80), shows a full-screen preview
  with a caption, shows the photo in the bubble and opens it full screen with pinch to zoom. Downloaded photos are
  kept in a small in-memory cache in `ApiMessagesRepository`.
