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
   Do the same for every extension id the project has (`app.hally.ShareExtension`, and the ones added later), each with
   the App Group.
2. In Xcode (or Codemagic), set your Team for every target under Signing & Capabilities; automatic signing creates the
   profiles.
3. Before App Store builds, `aps-environment` is switched to `production` by Xcode's archive export automatically.

## Building without a Mac

- **CI** proves it compiles but produces no installable app (no signing).
- **Codemagic** (or another cloud Mac) can sign and upload to TestFlight: connect the repository, add the App Store
  Connect API key, put `GoogleService-Info.plist` and `Secrets.xcconfig` in as files/environment, and run
  `flutter build ipa`. TestFlight then installs it on your iPhone.
