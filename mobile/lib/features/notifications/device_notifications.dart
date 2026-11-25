import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design/tokens.dart';
import '../../core/api/api_client.dart';
import '../../core/auth/auth_repository.dart';
import '../../core/auth/token_storage.dart';
import '../../core/locale/app_language.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../router.dart';
import '../home/live_timers.dart';
import '../asks/asks.dart' show ApiAsksRepository;
import '../medications/medications_repository.dart';

/// What a notification belongs to and what its buttons act on. Travels as the notification payload (JSON), so
/// the action handler also works in the background isolate, with the app closed.
class NotificationTarget {
  const NotificationTarget({required this.type, required this.familyId, required this.id});

  factory NotificationTarget.fromPayload(String payload) {
    final j = jsonDecode(payload) as Map<String, dynamic>;
    return NotificationTarget(type: j['type'] as String, familyId: j['familyId'] as String, id: j['id'] as String);
  }

  /// `screen`, `study`, `sleep` (id = child id), `med` (id = medication id) or `ask` (id = a child's request).
  final String type;
  final String familyId;
  final String id;

  String toPayload() => jsonEncode({'type': type, 'familyId': familyId, 'id': id});

  /// The screen a tap on the notification opens.
  String get route => switch (type) {
        'screen' => '/screen-time',
        'study' => '/study',
        'sleep' => '/sleep',
        'med' => '/medications',
        'ask' => '/asks',
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

/// Timer types that get an ongoing notification and a Durdur button.
const liveTimerTypes = ['screen', 'study', 'sleep'];

NotificationTarget timerTarget(LiveTimer t) => NotificationTarget(type: t.type, familyId: t.familyId, id: t.childId);

/// The timers this user started. The other parent's timers stay in the app and the widget, so a timer stopped on
/// another phone never leaves a stale notification here while this app is closed.
List<LiveTimer> myTimers(List<LiveTimer> timers, String userId) => [
      for (final t in timers)
        if (t.startedByUserId == userId) t
    ];

/// The phone's notification tray. [LocalDeviceNotifications] on Android, a no-op elsewhere and in tests.
abstract interface class DeviceNotifications {
  /// [onTap] gets the target of a tapped notification, also the one that started the app. [l10n] names the
  /// buttons (iPhone registers them up front).
  Future<void> init(void Function(NotificationTarget target) onTap, AppLocalizations l10n);

  /// An ongoing notification with a live clock and a Durdur button; on Android 16 also a chip in the status bar.
  /// On iPhone a Live Activity (lock screen and Dynamic Island).
  Future<void> showTimer(LiveTimer timer, AppLocalizations l10n);

  /// A medication reminder from the server (`kind=MedicationDue`, data-only on Android) with a "Verdim" button.
  Future<void> showMedicationDue(NotificationTarget target, String title, String body, AppLocalizations l10n);

  /// A child's request from the server (`kind=ChildAsk`, data-only on Android) with Evet / Hayır.
  Future<void> showChildAsk(NotificationTarget target, String title, String body, AppLocalizations l10n);
  Future<void> cancel(NotificationTarget target);

  /// Targets of the notifications of [type] this app shows now.
  Future<List<NotificationTarget>> active(String type);
  Future<void> cancelAll();
}

class NoDeviceNotifications implements DeviceNotifications {
  @override
  Future<void> init(void Function(NotificationTarget target) onTap, AppLocalizations l10n) async {}
  @override
  Future<void> showTimer(LiveTimer timer, AppLocalizations l10n) async {}
  @override
  Future<void> showMedicationDue(NotificationTarget target, String title, String body, AppLocalizations l10n) async {}
  @override
  Future<void> showChildAsk(NotificationTarget target, String title, String body, AppLocalizations l10n) async {}
  @override
  Future<void> cancel(NotificationTarget target) async {}
  @override
  Future<List<NotificationTarget>> active(String type) async => const [];
  @override
  Future<void> cancelAll() async {}
}

const notificationIcon = '@mipmap/ic_launcher_monochrome';
const _cherry = HallyColors.cherry;
const stopTimerAction = 'timer.stop';

/// The action id of the first version (screen time only); old notifications may still carry it.
const stopScreenTimeAction = 'screen.stop';
const giveMedicationAction = 'med.given';
const askYesAction = 'ask.yes';
const askNoAction = 'ask.no';

/// iPhone action category of a child's request (PushSender.AskCategory on the server).
const askCategory = 'hally.ask';

/// iPhone action category of the medication reminder (the server's push uses it too: PushSender.cs).
const medicationCategory = 'hally.med';

/// Settings for every `initialize` call. iPhone permission is asked by push (Firebase), not here.
const notificationInitSettings = InitializationSettings(
  android: AndroidInitializationSettings(notificationIcon),
  iOS: DarwinInitializationSettings(requestAlertPermission: false, requestBadgePermission: false, requestSoundPermission: false),
);

class LocalDeviceNotifications implements DeviceNotifications {
  final _plugin = FlutterLocalNotificationsPlugin();
  Future<void>? _ready;

  @override
  Future<void> init(void Function(NotificationTarget target) onTap, AppLocalizations l10n) => _ready ??= _init(onTap);

  /// For a background isolate (a push while the app is closed): no tap handling, no permission prompt.
  Future<void> initBackground() => _ready ??= _plugin
      .initialize(
        settings: notificationInitSettings,
        onDidReceiveBackgroundNotificationResponse: hallyNotificationAction,
      )
      .then((_) {});

  Future<void> _init(void Function(NotificationTarget target) onTap) async {
    void open(NotificationResponse r) {
      final payload = r.payload;
      if (payload != null && r.actionId == null) onTap(NotificationTarget.fromPayload(payload));
    }

    await _plugin.initialize(
      settings: notificationInitSettings,
      onDidReceiveNotificationResponse: open,
      onDidReceiveBackgroundNotificationResponse: hallyNotificationAction,
    );
    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true && launch!.notificationResponse != null) open(launch.notificationResponse!);
    // Android 13+ asks once; push asks too, this covers phones without Firebase.
    await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
  }

  @override
  Future<void> showTimer(LiveTimer t, AppLocalizations l10n) async {
    await _ready;
    final now = DateTime.now();
    await _plugin.show(
      id: notificationIdFor(t.type, t.childId),
      title: t.title,
      body: t.body,
      payload: timerTarget(t).toPayload(),
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          'live_timers',
          l10n.liveTimerChannel,
          channelDescription: l10n.liveTimerChannelDescription,
          icon: notificationIcon,
          color: _cherry,
          importance: Importance.low,
          priority: Priority.low,
          playSound: false,
          enableVibration: false,
          onlyAlertOnce: true,
          ongoing: true,
          autoCancel: false,
          showWhen: true,
          when: t.countingSince.millisecondsSinceEpoch,
          usesChronometer: true,
          // Android 16+: a "live update" with the running time as a chip in the status bar.
          requestPromotedOngoing: true,
          category: AndroidNotificationCategory.stopwatch,
          visibility: NotificationVisibility.public,
          timeoutAfter: t.until == null ? null : t.until!.difference(now).inMilliseconds.clamp(1000, 1 << 31),
          actions: [AndroidNotificationAction(stopTimerAction, l10n.screenNoticeStop, cancelNotification: false)],
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
          icon: notificationIcon,
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
  Future<void> showChildAsk(NotificationTarget target, String title, String body, AppLocalizations l10n) async {
    await _ready;
    await _plugin.show(
      id: notificationIdFor(target.type, target.id),
      title: title,
      body: body,
      payload: target.toPayload(),
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          'asks',
          l10n.askNoticeChannel,
          channelDescription: l10n.askNoticeChannelDescription,
          icon: notificationIcon,
          color: _cherry,
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.message,
          actions: [
            AndroidNotificationAction(askYesAction, l10n.askYes, cancelNotification: false),
            AndroidNotificationAction(askNoAction, l10n.askNo, cancelNotification: false),
          ],
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

/// iPhone: running timers as Live Activities (app.hally/live_activities, ios/Runner/LiveActivities.swift) and the
/// medication reminder with its "Verdim" button. The reminder push itself comes from the server with the
/// `hally.med` category; this draws it only while the app is open (iOS hides pushes in the foreground).
class IosDeviceNotifications implements DeviceNotifications {
  static const _activities = MethodChannel('app.hally/live_activities');
  final _plugin = FlutterLocalNotificationsPlugin();
  Future<void>? _ready;

  @override
  Future<void> init(void Function(NotificationTarget target) onTap, AppLocalizations l10n) => _ready ??= () async {
        void open(NotificationResponse r) {
          final payload = r.payload;
          if (payload != null && r.actionId == null) onTap(NotificationTarget.fromPayload(payload));
        }

        await _plugin.initialize(
          settings: InitializationSettings(
            iOS: DarwinInitializationSettings(
              requestAlertPermission: false,
              requestBadgePermission: false,
              requestSoundPermission: false,
              notificationCategories: [
                DarwinNotificationCategory(medicationCategory, actions: [DarwinNotificationAction.plain(giveMedicationAction, l10n.medNoticeGiven)]),
                DarwinNotificationCategory(askCategory, actions: [
                  DarwinNotificationAction.plain(askYesAction, l10n.askYes),
                  DarwinNotificationAction.plain(askNoAction, l10n.askNo),
                ]),
              ],
            ),
          ),
          onDidReceiveNotificationResponse: open,
          onDidReceiveBackgroundNotificationResponse: hallyNotificationAction,
        );
        final launch = await _plugin.getNotificationAppLaunchDetails();
        if (launch?.didNotificationLaunchApp == true && launch!.notificationResponse != null) open(launch.notificationResponse!);
      }();

  @override
  Future<void> showTimer(LiveTimer t, AppLocalizations l10n) async {
    await _ready;
    await _activities.invokeMethod<bool>('show', {
      'key': t.key,
      ...t.toJson(),
      'stopLabel': l10n.screenNoticeStop,
    });
  }

  @override
  Future<void> showMedicationDue(NotificationTarget target, String title, String body, AppLocalizations l10n) async {
    await _ready;
    await _plugin.show(
      id: notificationIdFor(target.type, target.id),
      title: title,
      body: body,
      payload: target.toPayload(),
      notificationDetails: const NotificationDetails(iOS: DarwinNotificationDetails(categoryIdentifier: medicationCategory)),
    );
  }

  @override
  Future<void> showChildAsk(NotificationTarget target, String title, String body, AppLocalizations l10n) async {
    await _ready;
    await _plugin.show(
      id: notificationIdFor(target.type, target.id),
      title: title,
      body: body,
      payload: target.toPayload(),
      notificationDetails: const NotificationDetails(iOS: DarwinNotificationDetails(categoryIdentifier: askCategory)),
    );
  }

  @override
  Future<void> cancel(NotificationTarget target) async {
    if (liveTimerTypes.contains(target.type)) {
      await _activities.invokeMethod<void>('end', {'key': '${target.type}:${target.id}'});
    } else {
      await _plugin.cancel(id: notificationIdFor(target.type, target.id));
    }
  }

  @override
  Future<List<NotificationTarget>> active(String type) async {
    if (!liveTimerTypes.contains(type)) return const [];
    final keys = await _activities.invokeListMethod<String>('keys') ?? const [];
    return [
      for (final key in keys)
        if (key.split(':') case [final t, final id] when t == type) NotificationTarget(type: t, familyId: '', id: id),
    ];
  }

  @override
  Future<void> cancelAll() async {
    await _activities.invokeMethod<void>('endAll');
    await _plugin.cancelAll();
  }
}

final deviceNotificationsProvider = Provider<DeviceNotifications>((ref) {
  if (kIsWeb || Platform.environment.containsKey('FLUTTER_TEST')) return NoDeviceNotifications();
  if (Platform.isAndroid) return LocalDeviceNotifications();
  if (Platform.isIOS) return IosDeviceNotifications();
  return NoDeviceNotifications();
});

/// Keeps the tray in step with the app: an ongoing notification for each timer (screen time, homework/reading,
/// sleep) this user started. Follows the live updates, so a stop on either phone removes it while the app runs.
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
  final locale = language.locale ?? resolveDeviceLocale(ref.watch(deviceLocaleProvider));
  final l10n = lookupAppLocalizations(locale);
  final ready = notifications.init((target) {
    final router = ref.read(routerProvider);
    router.push(target.route);
  }, l10n);

  // What is on screen now, by timer key, to skip identical re-posts.
  final shown = <String, String>{};
  var cleaned = false;

  Future<void> sync(List<LiveTimer> timers) async {
    await ready;
    final mine = myTimers(timers, userId);
    final wanted = {for (final t in mine) t.key: t};

    // Left from an earlier run of the app (it was closed while the timer stopped elsewhere).
    if (!cleaned) {
      cleaned = true;
      for (final type in liveTimerTypes) {
        for (final t in await notifications.active(type)) {
          if (!wanted.containsKey('${t.type}:${t.id}')) await notifications.cancel(t);
        }
      }
    }
    for (final key in shown.keys.where((k) => !wanted.containsKey(k)).toList()) {
      shown.remove(key);
      final [type, id] = key.split(':');
      await notifications.cancel(NotificationTarget(type: type, familyId: familyId, id: id));
    }
    for (final t in mine) {
      // Recomputing "since" can move it by a second; that is not a change worth re-posting.
      final key = '${t.countingSince.millisecondsSinceEpoch ~/ 10000}|${(t.until?.millisecondsSinceEpoch ?? 0) ~/ 60000}|${t.title}|${t.body}';
      if (shown[t.key] == key) continue;
      shown[t.key] = key;
      await notifications.showTimer(t, l10n);
    }
  }

  ref.listen(liveTimersProvider((familyId: familyId, language: locale.languageCode)), (_, timers) {
    if (timers != null) unawaited(sync(timers).catchError((Object e) => debugPrint('notifications: $e')));
  }, fireImmediately: true);
});

// ---------------------------------------------------------------------------------------------------------------
// Background isolate: notification buttons. Android runs this without the app's UI, also when the app is closed.

/// Tokens for the background isolate. If a refresh fails here (the app may have rotated the refresh token at the
/// same moment), the stored session is kept: only the app itself signs the user out.
class KeepSessionTokens implements TokenStorage {
  KeepSessionTokens(this._inner);

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

/// Evet/Hayır came second: the other parent already answered the child's request.
class ActionAskTaken extends ActionResult {
  const ActionAskTaken();
}

/// Runs a notification button against the API.
Future<ActionResult> runNotificationAction(ApiClient api, String actionId, NotificationTarget target) async {
  try {
    switch (actionId) {
      case stopTimerAction || stopScreenTimeAction:
        final path = switch (target.type) {
          'screen' => 'screen-time/stop',
          'study' => 'study/stop',
          'sleep' => 'sleep/stop',
          _ => null,
        };
        if (path == null) return const ActionFailed();
        await api.dio.post<void>('/api/v1/families/${target.familyId}/children/${target.id}/$path', data: const <String, Object?>{});
        return const ActionDone();
      case giveMedicationAction:
        await ApiMedicationsRepository(api).give(target.familyId, target.id);
        return const ActionDone();
      case askYesAction || askNoAction:
        await ApiAsksRepository(api).answer(target.familyId, target.id, yes: actionId == askYesAction);
        return const ActionDone();
    }
  } on DoseWarning catch (w) {
    return ActionDoseRefused(w);
  } on ApiException catch (e) {
    if (e.code == 'ask.already_answered' || e.code == 'ask.expired') return const ActionAskTaken();
    debugPrint('notification action $actionId failed: $e');
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
  final askId = data['askId'];
  if (familyId is String && askId is String) {
    final target = NotificationTarget(type: 'ask', familyId: familyId, id: askId);
    switch (data['kind']) {
      case 'ChildAsk':
        await notifications.showChildAsk(target, '${data['title'] ?? ''}', '${data['body'] ?? ''}', l10n);
        return true;
      case 'ChildAskAnswered':
        // The other parent answered first: the Evet/Hayır notification on this phone is done.
        await notifications.cancel(target);
        return false;
    }
    return false;
  }
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
  final result = await runNotificationAction(ApiClient(KeepSessionTokens(SecureTokenStorage())), actionId, target);

  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(settings: notificationInitSettings);
  if (result is ActionDone || result is ActionDoseRefused || result is ActionAskTaken) {
    // Done, or someone already gave the dose / answered the request: the notification is over either way.
    await plugin.cancel(id: notificationIdFor(target.type, target.id));
  }
  final notice = actionNotice(result, await backgroundLocalizations());
  if (notice == null) return;
  await plugin.show(
    id: notificationIdFor('failed', target.id),
    title: notice.title,
    body: notice.body,
    payload: target.toPayload(),
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails('actions', notice.channel, icon: notificationIcon, color: _cherry, importance: Importance.defaultImportance),
      iOS: const DarwinNotificationDetails(),
    ),
  );
}

/// What to tell the user after a notification button, or null when it simply worked.
({String title, String body, String channel})? actionNotice(ActionResult result, AppLocalizations l10n) {
  switch (result) {
    case ActionDone():
      return null;
    case ActionDoseRefused(:final warning):
      // Someone already gave it, so the reminder is done; say who and when instead.
      final last = warning.lastDose;
      return (
        title: l10n.medNoticeRefusedTitle,
        body: warning.isDailyLimit ? l10n.medNoticeRefusedDailyLimit : l10n.medNoticeRefusedBody(_clock(last.givenAt), last.givenByName ?? ''),
        channel: l10n.noticeActionChannel,
      );
    case ActionAskTaken():
      return (title: l10n.askNoticeTakenTitle, body: l10n.askNoticeTakenBody, channel: l10n.noticeActionChannel);
    case ActionFailed():
      // Leave the original in place and say why nothing happened.
      return (title: l10n.noticeActionFailedTitle, body: l10n.noticeActionFailedBody, channel: l10n.noticeActionChannel);
  }
}
