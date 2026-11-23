import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:ui' show Color, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/auth/auth_repository.dart';
import '../../core/auth/token_storage.dart';
import '../../core/locale/app_language.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../router.dart';
import '../family/family_repository.dart';
import '../medications/medications_repository.dart';
import '../screen_time/screen_time_repository.dart';

/// What a notification belongs to and what its buttons act on. Travels as the notification payload (JSON), so
/// the action handler also works in the background isolate, with the app closed.
class NotificationTarget {
  const NotificationTarget({required this.type, required this.familyId, required this.id});

  factory NotificationTarget.fromPayload(String payload) {
    final j = jsonDecode(payload) as Map<String, dynamic>;
    return NotificationTarget(type: j['type'] as String, familyId: j['familyId'] as String, id: j['id'] as String);
  }

  /// `screen` (id = child id) or `med` (id = medication id).
  final String type;
  final String familyId;
  final String id;

  String toPayload() => jsonEncode({'type': type, 'familyId': familyId, 'id': id});

  /// The screen a tap on the notification opens.
  String get route => switch (type) {
        'screen' => '/screen-time',
        'med' => '/medications',
        _ => '/notifications',
      };
}

/// Stable notification id for a target (Dart's String.hashCode is not guaranteed across runs).
int notificationIdFor(String type, String id) {
  var h = 0x811c9dc5;
  for (final c in '$type:$id'.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0x7fffffff;
  }
  return h;
}

/// A running screen time timer as an ongoing notification.
class ScreenTimeNotice {
  const ScreenTimeNotice({required this.familyId, required this.childId, required this.title, required this.body, required this.countingSince, this.until});

  final String familyId;
  final String childId;
  final String title;
  final String body;

  /// Android's chronometer counts up from here, so it shows today's total, not only this session.
  final DateTime countingSince;

  /// The server's 8 hour cap: the notification goes away by itself then, even if the app is closed.
  final DateTime? until;

  NotificationTarget get target => NotificationTarget(type: 'screen', familyId: familyId, id: childId);
}

/// The timers this user started that are running now. The other parent's timers stay in the app, so a timer
/// stopped on another phone never leaves a stale notification here while this app is closed.
List<ScreenTimeNotice> screenTimeNotices({
  required String familyId,
  required String userId,
  required Map<String, ChildScreenTime> statuses,
  required Map<String, String> childNames,
  required AppLocalizations l10n,
  required DateTime now,
}) =>
    [
      for (final s in statuses.values)
        if (s.isRunning && s.startedByUserId == userId)
          ScreenTimeNotice(
            familyId: familyId,
            childId: s.childId,
            title: l10n.screenNoticeTitle(childNames[s.childId] ?? ''),
            body: s.dailyGoalMinutes == null ? l10n.screenNoticeBody : l10n.screenNoticeGoal(s.dailyGoalMinutes!),
            countingSince: now.subtract(Duration(seconds: s.secondsAt(now))),
            until: s.runningUntil != null && s.asOf != null ? now.add(s.runningUntil!.difference(s.asOf!)) : null,
          ),
    ];

/// The phone's notification tray. [LocalDeviceNotifications] on Android, a no-op elsewhere and in tests.
abstract interface class DeviceNotifications {
  /// [onTap] gets the target of a tapped notification, also the one that started the app.
  Future<void> init(void Function(NotificationTarget target) onTap);
  Future<void> showScreenTime(ScreenTimeNotice notice, AppLocalizations l10n);

  /// A medication reminder from the server (`kind=MedicationDue`, data-only on Android) with a "Verdim" button.
  Future<void> showMedicationDue(NotificationTarget target, String title, String body, AppLocalizations l10n);
  Future<void> cancel(NotificationTarget target);

  /// Targets of the notifications of [type] this app shows now.
  Future<List<NotificationTarget>> active(String type);
  Future<void> cancelAll();
}

class NoDeviceNotifications implements DeviceNotifications {
  @override
  Future<void> init(void Function(NotificationTarget target) onTap) async {}
  @override
  Future<void> showScreenTime(ScreenTimeNotice notice, AppLocalizations l10n) async {}
  @override
  Future<void> showMedicationDue(NotificationTarget target, String title, String body, AppLocalizations l10n) async {}
  @override
  Future<void> cancel(NotificationTarget target) async {}
  @override
  Future<List<NotificationTarget>> active(String type) async => const [];
  @override
  Future<void> cancelAll() async {}
}

const _icon = '@mipmap/ic_launcher_monochrome';
const _cherry = Color(0xFFA8133C);
const stopScreenTimeAction = 'screen.stop';
const giveMedicationAction = 'med.given';

class LocalDeviceNotifications implements DeviceNotifications {
  final _plugin = FlutterLocalNotificationsPlugin();
  Future<void>? _ready;

  @override
  Future<void> init(void Function(NotificationTarget target) onTap) => _ready ??= _init(onTap);

  /// For a background isolate (a push while the app is closed): no tap handling, no permission prompt.
  Future<void> initBackground() => _ready ??= _plugin
      .initialize(
        settings: const InitializationSettings(android: AndroidInitializationSettings(_icon)),
        onDidReceiveBackgroundNotificationResponse: hallyNotificationAction,
      )
      .then((_) {});

  Future<void> _init(void Function(NotificationTarget target) onTap) async {
    void open(NotificationResponse r) {
      final payload = r.payload;
      if (payload != null && r.actionId == null) onTap(NotificationTarget.fromPayload(payload));
    }

    await _plugin.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings(_icon)),
      onDidReceiveNotificationResponse: open,
      onDidReceiveBackgroundNotificationResponse: hallyNotificationAction,
    );
    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true && launch!.notificationResponse != null) open(launch.notificationResponse!);
    // Android 13+ asks once; push asks too, this covers phones without Firebase.
    await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
  }

  @override
  Future<void> showScreenTime(ScreenTimeNotice n, AppLocalizations l10n) async {
    await _ready;
    final now = DateTime.now();
    await _plugin.show(
      id: notificationIdFor('screen', n.childId),
      title: n.title,
      body: n.body,
      payload: n.target.toPayload(),
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          'screen_time',
          l10n.screenNoticeChannel,
          channelDescription: l10n.screenNoticeChannelDescription,
          icon: _icon,
          color: _cherry,
          importance: Importance.low,
          priority: Priority.low,
          playSound: false,
          enableVibration: false,
          onlyAlertOnce: true,
          ongoing: true,
          autoCancel: false,
          showWhen: true,
          when: n.countingSince.millisecondsSinceEpoch,
          usesChronometer: true,
          category: AndroidNotificationCategory.stopwatch,
          visibility: NotificationVisibility.public,
          timeoutAfter: n.until == null ? null : n.until!.difference(now).inMilliseconds.clamp(1000, 1 << 31),
          actions: [AndroidNotificationAction(stopScreenTimeAction, l10n.screenNoticeStop, cancelNotification: false)],
        ),
      ),
    );
  }

  @override
  Future<void> showMedicationDue(NotificationTarget target, String title, String body, AppLocalizations l10n) async {
    await _ready;
    await _plugin.show(
      id: notificationIdFor(target.type, target.id),
      title: title,
      body: body,
      payload: target.toPayload(),
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          'medications',
          l10n.medNoticeChannel,
          channelDescription: l10n.medNoticeChannelDescription,
          icon: _icon,
          color: _cherry,
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.reminder,
          // The medicine's name stays hidden on a locked phone if the user chose "hide sensitive content".
          visibility: NotificationVisibility.private,
          actions: [AndroidNotificationAction(giveMedicationAction, l10n.medNoticeGiven, cancelNotification: false)],
        ),
      ),
    );
  }

  @override
  Future<void> cancel(NotificationTarget target) => _plugin.cancel(id: notificationIdFor(target.type, target.id));

  @override
  Future<List<NotificationTarget>> active(String type) async {
    final shown = await _plugin.getActiveNotifications();
    return [
      for (final n in shown)
        if (n.payload case final p? when p.startsWith('{'))
          if (NotificationTarget.fromPayload(p) case final t when t.type == type) t,
    ];
  }

  @override
  Future<void> cancelAll() => _plugin.cancelAll();
}

final deviceNotificationsProvider = Provider<DeviceNotifications>((ref) {
  if (kIsWeb || !Platform.isAndroid || Platform.environment.containsKey('FLUTTER_TEST')) return NoDeviceNotifications();
  return LocalDeviceNotifications();
});

/// Keeps the tray in step with the app: an ongoing notification for each screen time timer this user started.
/// Follows the live updates of [screenTimeProvider], so a stop on either phone removes it while the app runs.
final deviceNotificationsSyncProvider = Provider<void>((ref) {
  final notifications = ref.watch(deviceNotificationsProvider);
  final userId = ref.watch(meProvider.select((me) => me.valueOrNull?.id));
  final familyId = ref.watch(meProvider.select((me) => me.valueOrNull?.primaryFamily?.id));
  final signedOut = ref.watch(meProvider.select((me) => me.hasValue && me.value == null));
  if (userId == null || familyId == null) {
    if (signedOut) unawaited(notifications.cancelAll().catchError((Object e) => debugPrint('notifications: $e')));
    return;
  }

  final language = ref.watch(languageProvider);
  final l10n = lookupAppLocalizations(language.locale ?? resolveDeviceLocale(ref.watch(deviceLocaleProvider)));
  final ready = notifications.init((target) {
    final router = ref.read(routerProvider);
    router.push(target.route);
  });

  // What is on screen now, by child id: running since + today's seconds + name, to skip identical re-posts.
  final shown = <String, String>{};
  var cleaned = false;

  Future<void> sync() async {
    await ready;
    final statuses = ref.read(screenTimeProvider(familyId)).valueOrNull;
    if (statuses == null) return;
    final names = <String, String>{for (final c in ref.read(familyProvider(familyId)).valueOrNull?.children ?? const <ChildProfile>[]) c.id: c.firstName};
    final now = DateTime.now();
    final notices = screenTimeNotices(familyId: familyId, userId: userId, statuses: statuses, childNames: names, l10n: l10n, now: now);
    final wanted = {for (final n in notices) n.childId: n};

    // Left from an earlier run of the app (it was closed while the timer stopped elsewhere).
    if (!cleaned) {
      cleaned = true;
      for (final t in await notifications.active('screen')) {
        if (!wanted.containsKey(t.id)) await notifications.cancel(t);
      }
    }
    for (final id in shown.keys.where((id) => !wanted.containsKey(id)).toList()) {
      shown.remove(id);
      await notifications.cancel(NotificationTarget(type: 'screen', familyId: familyId, id: id));
    }
    for (final n in notices) {
      final s = statuses[n.childId]!;
      final key = '${s.runningSince}|${s.todaySeconds}|${n.title}|${n.body}';
      if (shown[n.childId] == key) continue;
      shown[n.childId] = key;
      await notifications.showScreenTime(n, l10n);
    }
  }

  void run() => unawaited(sync().catchError((Object e) => debugPrint('notifications: $e')));
  ref.listen(screenTimeProvider(familyId), (_, __) => run(), fireImmediately: true);
  ref.listen(familyProvider(familyId), (_, __) => run());
});

// ---------------------------------------------------------------------------------------------------------------
// Background isolate: notification buttons. Android runs this without the app's UI, also when the app is closed.

/// Tokens for the background isolate. If a refresh fails here (the app may have rotated the refresh token at the
/// same moment), the stored session is kept: only the app itself signs the user out.
class _KeepSessionTokens implements TokenStorage {
  _KeepSessionTokens(this._inner);

  final TokenStorage _inner;

  @override
  Future<StoredTokens?> read() => _inner.read();
  @override
  Future<void> write(StoredTokens tokens) => _inner.write(tokens);
  @override
  Future<void> clear() async {}
}

/// What a notification button did.
sealed class ActionResult {
  const ActionResult();
}

class ActionDone extends ActionResult {
  const ActionDone();
}

/// "Verdim" was not saved because the dose comes too soon: someone already gave it (or the daily limit is
/// reached). From the lock screen Hally never overrides that; the app asks first.
class ActionDoseRefused extends ActionResult {
  const ActionDoseRefused(this.warning);

  final DoseWarning warning;
}

class ActionFailed extends ActionResult {
  const ActionFailed();
}

/// Runs a notification button against the API.
Future<ActionResult> runNotificationAction(ApiClient api, String actionId, NotificationTarget target) async {
  try {
    switch (actionId) {
      case stopScreenTimeAction:
        await api.dio.post<void>('/api/v1/families/${target.familyId}/children/${target.id}/screen-time/stop');
        return const ActionDone();
      case giveMedicationAction:
        await ApiMedicationsRepository(api).give(target.familyId, target.id);
        return const ActionDone();
    }
  } on DoseWarning catch (w) {
    return ActionDoseRefused(w);
  } catch (e) {
    debugPrint('notification action $actionId failed: $e');
  }
  return const ActionFailed();
}

String _clock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// The language the app shows, also from a background isolate.
Future<AppLocalizations> backgroundLocalizations() async {
  final language = await SecureLanguageStorage().read();
  return lookupAppLocalizations(language.locale ?? resolveDeviceLocale(PlatformDispatcher.instance.locale));
}

/// A push from the server that the app draws or clears itself. Used for pushes in the background (FCM's
/// background isolate) and while the app is open. Returns true when it handled the push.
Future<bool> handleNotificationPush(Map<String, dynamic> data, DeviceNotifications notifications, AppLocalizations l10n) async {
  final familyId = data['familyId'];
  final medicationId = data['medicationId'];
  if (familyId is! String || medicationId is! String) return false;
  final target = NotificationTarget(type: 'med', familyId: familyId, id: medicationId);
  switch (data['kind']) {
    case 'MedicationDue':
      await notifications.showMedicationDue(target, '${data['title'] ?? ''}', '${data['body'] ?? ''}', l10n);
      return true;
    case 'MedicationGiven':
      // The other parent gave it: the reminder on this phone is done.
      await notifications.cancel(target);
      return false;
  }
  return false;
}

@pragma('vm:entry-point')
Future<void> hallyNotificationAction(NotificationResponse response) async {
  final actionId = response.actionId;
  final payload = response.payload;
  if (actionId == null || payload == null) return;
  final target = NotificationTarget.fromPayload(payload);
  final result = await runNotificationAction(ApiClient(_KeepSessionTokens(SecureTokenStorage())), actionId, target);

  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(settings: const InitializationSettings(android: AndroidInitializationSettings(_icon)));
  if (result is ActionDone) {
    await plugin.cancel(id: notificationIdFor(target.type, target.id));
    return;
  }
  final l10n = await backgroundLocalizations();
  final String title;
  final String body;
  if (result is ActionDoseRefused) {
    // Someone already gave it, so the reminder is done; say who and when instead.
    await plugin.cancel(id: notificationIdFor(target.type, target.id));
    final last = result.warning.lastDose;
    title = l10n.medNoticeRefusedTitle;
    body = result.warning.isDailyLimit
        ? l10n.medNoticeRefusedDailyLimit
        : l10n.medNoticeRefusedBody(_clock(last.givenAt), last.givenByName ?? '');
  } else {
    // Leave the original in place and say why nothing happened.
    title = l10n.noticeActionFailedTitle;
    body = l10n.noticeActionFailedBody;
  }
  await plugin.show(
    id: notificationIdFor('failed', target.id),
    title: title,
    body: body,
    payload: target.toPayload(),
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails('actions', l10n.noticeActionChannel, icon: _icon, color: _cherry, importance: Importance.defaultImportance),
    ),
  );
}
