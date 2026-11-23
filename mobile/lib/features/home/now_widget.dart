import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:home_widget/home_widget.dart';

import '../../core/api/api_client.dart';
import '../../core/auth/auth_repository.dart';
import '../../core/auth/token_storage.dart';
import '../../core/locale/app_language.dart';
import '../../l10n/gen/app_localizations.dart';
import '../notifications/device_notifications.dart';
import 'live_timers.dart';

/// What the native "Şu an" widget reads: every running timer of the family with its start, plus the texts in the
/// app's language. The widget's own clocks tick by themselves (Android Chronometer), so nothing is rewritten per second.
Map<String, String> nowWidgetData(List<LiveTimer> timers, AppLocalizations l10n) => {
      'now.items': jsonEncode([for (final t in timers) t.toJson()]),
      'now.title': l10n.nowWidgetTitle,
      'now.empty': l10n.nowWidgetEmpty,
      'now.count': l10n.nowWidgetCount(999).replaceFirst('999', '%d'),
      'now.stop': l10n.nowWidgetStop,
    };

/// The Durdur button of a widget row: `hally://timer/stop?type=screen&family=..&child=..`.
NotificationTarget? nowWidgetStopTarget(Uri? uri) {
  if (uri == null || uri.host != 'timer' || uri.path != '/stop') return null;
  final type = uri.queryParameters['type'];
  final family = uri.queryParameters['family'];
  final child = uri.queryParameters['child'];
  if (type == null || family == null || child == null || !liveTimerTypes.contains(type)) return null;
  return NotificationTarget(type: type, familyId: family, id: child);
}

/// [items] (the stored JSON) without the stopped timer.
String nowWidgetWithout(String items, NotificationTarget target) => jsonEncode([
      for (final t in (jsonDecode(items) as List).cast<Map<String, dynamic>>())
        if (!(t['type'] == target.type && t['childId'] == target.id)) t,
    ]);

abstract interface class NowWidgetStore {
  Future<void> save(Map<String, String> data, List<DateTime> refreshAt);
  Future<void> clear();
}

class HomeWidgetNowStore implements NowWidgetStore {
  static const provider = 'app.hally.hally.NowWidgetProvider';
  bool _registered = false;

  @override
  Future<void> save(Map<String, String> data, List<DateTime> refreshAt) async {
    if (!_registered) {
      _registered = true;
      await HomeWidget.registerInteractivityCallback(hallyWidgetAction);
    }
    for (final e in data.entries) {
      await HomeWidget.saveWidgetData<String>(e.key, e.value);
    }
    await HomeWidget.updateWidget(qualifiedAndroidName: provider);
    // A forgotten timer leaves the widget at the server's cap, also while the app is closed.
    if (refreshAt.isNotEmpty) await HomeWidget.scheduleWidgetUpdates(refreshAt, qualifiedAndroidName: provider);
  }

  @override
  Future<void> clear() async {
    await HomeWidget.saveWidgetData<String>('now.items', null);
    await HomeWidget.updateWidget(qualifiedAndroidName: provider);
  }
}

class NoNowWidgetStore implements NowWidgetStore {
  @override
  Future<void> save(Map<String, String> data, List<DateTime> refreshAt) async {}
  @override
  Future<void> clear() async {}
}

final nowWidgetStoreProvider = Provider<NowWidgetStore>((ref) {
  if (kIsWeb || !Platform.isAndroid || Platform.environment.containsKey('FLUTTER_TEST')) return NoNowWidgetStore();
  return HomeWidgetNowStore();
});

/// Keeps the "Şu an" widget in step with the family's running timers while the app runs. When the app is closed
/// the widget keeps counting; a timer stopped on another phone then leaves the widget at the next app start, or
/// right away when its Durdur is tapped (the server says it already stopped).
final nowWidgetSyncProvider = Provider<void>((ref) {
  final store = ref.watch(nowWidgetStoreProvider);
  final familyId = ref.watch(meProvider.select((me) => me.valueOrNull?.primaryFamily?.id));
  final signedOut = ref.watch(meProvider.select((me) => me.hasValue && me.value == null));
  if (familyId == null) {
    if (signedOut) unawaited(store.clear().catchError((Object e) => debugPrint('widget: $e')));
    return;
  }
  final language = ref.watch(languageProvider);
  final locale = language.locale ?? resolveDeviceLocale(ref.watch(deviceLocaleProvider));
  final l10n = lookupAppLocalizations(locale);

  String? last;
  ref.listen(liveTimersProvider((familyId: familyId, language: locale.languageCode)), (_, timers) {
    if (timers == null) return;
    final data = nowWidgetData(timers, l10n);
    // Same timers (to the second) as last time: nothing to redraw.
    final signature = jsonEncode([for (final t in timers) '${t.key}|${t.countingSince.millisecondsSinceEpoch ~/ 10000}|${t.title}|${t.body}']);
    if (signature == last) return;
    last = signature;
    final now = DateTime.now();
    final refresh = {for (final t in timers) if (t.until case final u? when u.isAfter(now)) u}.toList()..sort();
    unawaited(store.save(data, refresh).catchError((Object e) => debugPrint('widget: $e')));
  }, fireImmediately: true);
});

/// Durdur on the widget. Runs in a background isolate, also when the app is closed.
@pragma('vm:entry-point')
Future<void> hallyWidgetAction(Uri? uri) async {
  final target = nowWidgetStopTarget(uri);
  if (target == null) return;
  final result = await runNotificationAction(ApiClient(KeepSessionTokens(SecureTokenStorage())), stopTimerAction, target);
  if (result is ActionFailed) {
    // 4xx from the server means the timer is not running any more (stopped on another phone): drop it too.
    debugPrint('widget: stop failed for ${target.type}');
  }
  final items = await HomeWidget.getWidgetData<String>('now.items');
  if (items != null && (result is ActionDone || await _notRunning(target))) {
    await HomeWidget.saveWidgetData<String>('now.items', nowWidgetWithout(items, target));
    await HomeWidget.updateWidget(qualifiedAndroidName: HomeWidgetNowStore.provider);
  }
  if (result is ActionDone) {
    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.initialize(settings: const InitializationSettings(android: AndroidInitializationSettings(notificationIcon)));
    await plugin.cancel(id: notificationIdFor(target.type, target.id));
  }
}

/// Whether the server says this timer is not running (so a stale widget row can go).
Future<bool> _notRunning(NotificationTarget target) async {
  try {
    final api = ApiClient(KeepSessionTokens(SecureTokenStorage()));
    final path = switch (target.type) {
      'screen' => 'screen-time',
      'study' => 'study',
      _ => 'sleep',
    };
    final res = await api.dio.get<Object>('/api/v1/families/${target.familyId}/$path');
    final body = res.data;
    final list = body is Map ? (body['children'] as List? ?? const []) : (body as List? ?? const []);
    for (final c in list.cast<Map<String, dynamic>>()) {
      if (c['childId'] != target.id) continue;
      return target.type == 'sleep' ? c['asleep'] == null : c['runningSince'] == null;
    }
    return true;
  } catch (_) {
    return false;
  }
}
