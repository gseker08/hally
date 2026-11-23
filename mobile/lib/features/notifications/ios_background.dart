import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:home_widget/home_widget.dart';

import '../../core/api/api_client.dart';
import '../../core/auth/token_storage.dart';
import '../home/now_widget.dart';
import 'device_notifications.dart';

/// The App Group the iPhone app shares with its widgets and share extension (ios/Runner/Runner.entitlements).
const iosAppGroup = 'group.app.hally';

/// Entry point of the iPhone background engine (ios/Runner/BackgroundDart.swift). It runs a button pressed outside
/// the app, without the UI and also when the app was closed: Durdur on a widget or a timer's Live Activity, and
/// Verdim on a medication reminder push.
@pragma('vm:entry-point')
Future<void> hallyIosBackgroundMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.hally/background');
  channel.setMethodCallHandler((call) async {
    if (call.method != 'run') throw MissingPluginException();
    return hallyIosBackgroundAction(Uri.parse(call.arguments as String));
  });
  await channel.invokeMethod<void>('ready');
}

/// Runs one link and returns the notice to show (`title`, `body`), or null when there is nothing to say.
Future<Map<String, String>?> hallyIosBackgroundAction(Uri uri) async {
  await HomeWidget.setAppGroupId(iosAppGroup);
  if (uri.host == 'timer') {
    await hallyWidgetAction(uri);
    return null;
  }
  final target = medGivenTarget(uri);
  if (target == null) return null;
  final result = await runNotificationAction(ApiClient(KeepSessionTokens(SecureTokenStorage())), giveMedicationAction, target);
  final notice = actionNotice(result, await backgroundLocalizations());
  return notice == null ? null : {'title': notice.title, 'body': notice.body};
}

/// `hally://med/given?family=..&med=..`, from Verdim on the iPhone medication reminder (AppDelegate.swift).
NotificationTarget? medGivenTarget(Uri uri) {
  if (uri.host != 'med' || uri.path != '/given') return null;
  final family = uri.queryParameters['family'];
  final med = uri.queryParameters['med'];
  if (family == null || med == null) return null;
  return NotificationTarget(type: 'med', familyId: family, id: med);
}
