# iPhone (iOS)

The Flutter code is shared with Android. The iOS project lives in `mobile/ios` and CI builds it on every pull request
(`ios` job in `.github/workflows/ci.yml`, `flutter build ios --release --no-codesign` on a macOS runner), so it is
known to compile without anyone owning a Mac.

## What is set up in the project

| Piece | Where |
|---|---|
| Bundle id `app.hally`, iOS 15+, iPhone and iPad | `Runner.xcodeproj` |
| Capabilities: Push (`aps-environment`), Sign in with Apple, App Group `group.app.hally` | `Runner/Runner.entitlements` |
| Background push (`remote-notification`) | `Runner/Info.plist` |
| Camera / photo permission texts in Turkish and English | `Runner/tr.lproj`, `Runner/en.lproj` (`InfoPlist.strings`) |
| Share extension ("Paylaş → Hally" for text, links and one image) | `ShareExtension/` (see `share-extension.md`) |
| Firebase config, copied into the app only if present | build phase "Copy GoogleService-Info.plist" |
| Google Sign-In URL scheme | `Flutter/Secrets.xcconfig` (git-ignored, from `Secrets.xcconfig.example`) |

## iPhone counterparts of the Android extras

| Android | iPhone | Code |
|---|---|---|
| "Bugün" home screen widget | "Bugün" widget: home screen (small, medium, large) and lock screen (rectangular, inline) | `HallyWidgets/TodayWidget.swift` |
| "Şu an" widget with Durdur | "Şu an" widget: home and lock screen; Durdur button from iOS 17 | `HallyWidgets/NowWidget.swift` |
| Ongoing timer notification + status bar chip | Live Activity on the lock screen and in the Dynamic Island, with Durdur (iOS 17) | `HallyWidgets/TimerLiveActivity.swift`, `Runner/LiveActivities.swift` |
| Medication reminder with Verdim | The server's push carries the `hally.med` category, so iOS shows Verdim; "given" replaces the reminder (same `apns-collapse-id`) | `PushSender.cs`, `Runner/AppDelegate.swift` |

How it fits together:
- The app writes the widget data to the App Group `group.app.hally` (home_widget, same keys as Android) and asks
  WidgetKit to redraw. The widgets plan their own redraws (an item leaving 15 minutes after it starts, midnight,
  a timer's cap), so they stay right while the app is closed.
- Live Activities are started by the app for the timers this user started (like Android's ongoing notification)
  and ended when the timer stops on either phone while the app runs; a forgotten one turns stale at the server's cap.
- Durdur and Verdim run Hally's Dart code in a background engine (`Runner/BackgroundDart.swift` →
  `lib/features/notifications/ios_background.dart`), which calls the API with the stored sign-in.
- Widgets and Live Activities need iOS 16.2+, the buttons iOS 17+; the app itself runs from iOS 15.

Login tokens are stored in the keychain as "after first unlock, this device only", so lock-screen buttons work while
the phone is locked and the tokens never move to another phone.

## Files only you have (git-ignored, like `google-services.json` on Android)

1. **`mobile/ios/Runner/GoogleService-Info.plist`**: Firebase console → project `hally-11922` → Add app → iOS,
   bundle id `app.hally` → download. Without it the app runs, just without push.
2. **APNs key in Firebase**: Apple Developer → Certificates, IDs & Profiles → Keys → "+" → Apple Push Notifications
   service → download the `.p8` once. Firebase console → Project settings → Cloud Messaging → Apple app configuration →
   upload the key with its Key ID and your Team ID. One key serves development and TestFlight/App Store.
3. **Google Sign-In (optional)**: Google Cloud Console → Credentials → Create OAuth client → iOS, bundle id `app.hally`.
   Put its "iOS URL scheme" into `mobile/ios/Flutter/Secrets.xcconfig` and build with
   `--dart-define=HALLY_GOOGLE_IOS_CLIENT_ID=<client id>`. Without it the iPhone app shows only Apple sign-in
   (plus the developer sign-in in debug builds).

## Apple Developer account steps

1. Identifiers → App IDs: `app.hally` with Push Notifications, Sign in with Apple and App Groups (`group.app.hally`).
   Do the same for the extensions `app.hally.ShareExtension` and `app.hally.HallyWidgets`, each with the App Group.
2. In Xcode (or Codemagic), set your Team for every target under Signing & Capabilities; automatic signing creates the
   profiles.
3. Before App Store builds, `aps-environment` is switched to `production` by Xcode's archive export automatically.

## Building without a Mac

- **CI** proves it compiles but produces no installable app (no signing).
- **Codemagic** signs and uploads to TestFlight with `codemagic.yaml`; setup steps are in [codemagic.md](codemagic.md).
