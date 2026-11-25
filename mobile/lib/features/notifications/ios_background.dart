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
/// Verdim on a medication reminder push, Evet/Hayır on a child's request.
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
  final api = ApiClient(KeepSessionTokens(SecureTokenStorage()));
  final ask = askAnswerTarget(uri);
  if (ask != null) {
    final result = await runNotificationAction(api, ask.yes ? askYesAction : askNoAction, ask.target);
    final notice = actionNotice(result, await backgroundLocalizations());
    return notice == null ? null : {'title': notice.title, 'body': notice.body};
  }
  final target = medGivenTarget(uri);
  if (target == null) return null;
  final result = await runNotificationAction(api, giveMedicationAction, target);
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

/// `hally://ask/answer?family=..&ask=..&yes=1|0`, from Evet/Hayır on a child's request push (AppDelegate.swift).
({NotificationTarget target, bool yes})? askAnswerTarget(Uri uri) {
  if (uri.host != 'ask' || uri.path != '/answer') return null;
  final family = uri.queryParameters['family'];
  final ask = uri.queryParameters['ask'];
  if (family == null || ask == null) return null;
  return (target: NotificationTarget(type: 'ask', familyId: family, id: ask), yes: uri.queryParameters['yes'] == '1');
}
