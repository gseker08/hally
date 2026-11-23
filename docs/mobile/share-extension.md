# Share into Hally (Android intent filters, iOS Share Extension)

The Dart side (`lib/features/share`) uses [`receive_sharing_intent`](https://pub.dev/packages/receive_sharing_intent).
`ShareListener` wraps the signed-in shell: a shared **text/link** or **image** becomes a capture with `source=Share`
and opens the approval screen. Only the first item of a multi-share is used, and video or other files are ignored.
Nothing is created until a parent approves it.


## Android

In `android/app/src/main/AndroidManifest.xml`, inside the main `<activity>` (keep `android:launchMode="singleTask"`):

```xml
<intent-filter>
  <action android:name="android.intent.action.SEND" />
  <category android:name="android.intent.category.DEFAULT" />
  <data android:mimeType="text/*" />
</intent-filter>
<intent-filter>
  <action android:name="android.intent.action.SEND" />
  <category android:name="android.intent.category.DEFAULT" />
  <data android:mimeType="image/*" />
</intent-filter>
```

## iOS

Done in the project (`mobile/ios/ShareExtension`): a Share Extension that subclasses `RSIShareViewController` and
opens the app right away, the App Group `group.app.hally` on Runner and the extension (`CUSTOM_GROUP_ID`), the
`ShareMedia-app.hally` URL scheme, and the `receive-sharing-intent` Swift package linked into the extension.
It accepts text, one link and one image. With an Apple Developer account, register `app.hally.ShareExtension` with
the same App Group (see `ios.md`).

## Manual test

Share a WhatsApp message and a screenshot to Hally while signed in. You should see the "Paylaşılan içerik okunuyor…" snackbar,
then the approval screen. If you share before signing in, the capture runs once you reach the home screen.
