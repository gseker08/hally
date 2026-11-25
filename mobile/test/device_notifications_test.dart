import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/api/api_client.dart';
import 'package:hally/core/auth/token_storage.dart';
import 'package:hally/features/notifications/device_notifications.dart';
import 'package:hally/features/home/live_timers.dart';
import 'package:hally/features/home/now_widget.dart';
import 'package:hally/features/screen_time/screen_time_repository.dart';
import 'package:hally/features/sleep/sleep_repository.dart';
import 'package:hally/features/study/study_repository.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

class _Tokens implements TokenStorage {
  @override
  Future<StoredTokens?> read() async => const StoredTokens(accessToken: 'a', refreshToken: 'r');
  @override
  Future<void> write(StoredTokens t) async {}
  @override
  Future<void> clear() async {}
}

class _Api implements HttpClientAdapter {
  _Api(this.status, [this.body = '{}']);

  final int status;
  final String body;
  final calls = <String>[];

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? body, Future<void>? cancel) async {
    calls.add('${o.method} ${o.path}${o.data == null ? '' : ' ${jsonEncode(o.data)}'}');
    return ResponseBody.fromString(this.body, status, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  nowWidgetTests();
  final tr = lookupAppLocalizations(const Locale('tr'));
  final now = DateTime(2026, 11, 23, 18, 0);

  ChildScreenTime status(String child, {String? by, int seconds = 600, int? goal}) => ChildScreenTime(
        childId: child,
        todaySeconds: seconds,
        receivedAt: now,
        dailyGoalMinutes: goal,
        runningSince: by == null ? null : DateTime.utc(2026, 11, 23, 14, 50),
        startedByUserId: by,
        asOf: DateTime.utc(2026, 11, 23, 15),
        runningUntil: DateTime.utc(2026, 11, 23, 22, 50),
      );

  test('all running timers of the family; only mine get a notification', () {
    final timers = liveTimers(
      familyId: 'f1',
      screen: {
        'c1': status('c1', by: 'me', seconds: 1500, goal: 60),
        'c2': status('c2', by: 'partner'),
        'c3': status('c3'),
      },
      study: {
        'c2': ChildStudyStatus(
            childId: 'c2',
            todaySeconds: 600,
            runningKind: 'Reading',
            runningSince: DateTime.utc(2026, 11, 23, 14, 55),
            dailyGoalMinutes: 30,
            startedByUserId: 'me',
            receivedAt: now),
      },
      sleep: {
        'c3': ChildSleepStatus(
            childId: 'c3', asleep: SleepEntry(id: 's1', childId: 'c3', kind: 'Nap', startedAt: DateTime(2026, 11, 23, 16, 55), startedByUserId: 'partner')),
      },
      childNames: {'c1': 'Ada', 'c2': 'Can', 'c3': 'Ela'},
      l10n: tr,
      now: now,
    );

    expect([
      for (final t in timers) '${t.emoji} ${t.title} · ${t.body}'
    ], [
      '📱 Ada · ekran süresi · Günlük hedef: 60 dk',
      '📱 Can · ekran süresi · Sayaç çalışıyor',
      '📖 Can · kitap okuma · Günlük hedef: 30 dk',
      '🌙 Ela uyuyor · Uyudu: 16:55',
    ]);
    final ada = timers.first;
    expect(ada.countingSince, now.subtract(const Duration(seconds: 1500)));
    expect(ada.until, now.add(const Duration(hours: 7, minutes: 50)));
    expect(timers.last.countingSince, DateTime(2026, 11, 23, 16, 55));

    expect([for (final t in myTimers(timers, 'me')) t.key], ['screen:c1', 'study:c2']);
  });

  test('payload round trip, route and stable ids', () {
    const t = NotificationTarget(type: 'screen', familyId: 'f1', id: 'c1');
    final back = NotificationTarget.fromPayload(t.toPayload());

    expect((back.type, back.familyId, back.id), ('screen', 'f1', 'c1'));
    expect(back.route, '/screen-time');
    expect(notificationIdFor('screen', 'c1'), notificationIdFor('screen', 'c1'));
    expect(notificationIdFor('screen', 'c1'), isNot(notificationIdFor('screen', 'c2')));
    expect(notificationIdFor('screen', 'c1'), greaterThanOrEqualTo(0));
  });

  test('the Durdur button stops the timer on the server', () async {
    final api = _Api(200);
    final client = ApiClient(_Tokens(), dio: Dio(BaseOptions(baseUrl: 'http://x'))..httpClientAdapter = api);

    final ok = await runNotificationAction(client, stopTimerAction, const NotificationTarget(type: 'screen', familyId: 'f1', id: 'c1'));

    expect(ok, isA<ActionDone>());
    expect(api.calls, ['POST /api/v1/families/f1/children/c1/screen-time/stop {}']);

    await runNotificationAction(client, stopTimerAction, const NotificationTarget(type: 'study', familyId: 'f1', id: 'c2'));
    await runNotificationAction(client, stopScreenTimeAction, const NotificationTarget(type: 'sleep', familyId: 'f1', id: 'c3'));
    expect(api.calls.skip(1), ['POST /api/v1/families/f1/children/c2/study/stop {}', 'POST /api/v1/families/f1/children/c3/sleep/stop {}']);
  });

  test('a failed call reports false so the notification stays', () async {
    final api = _Api(500);
    final client = ApiClient(_Tokens(), dio: Dio(BaseOptions(baseUrl: 'http://x'))..httpClientAdapter = api);

    expect(await runNotificationAction(client, stopScreenTimeAction, const NotificationTarget(type: 'screen', familyId: 'f1', id: 'c1')), isA<ActionFailed>());
    expect(await runNotificationAction(client, 'unknown', const NotificationTarget(type: 'screen', familyId: 'f1', id: 'c1')), isA<ActionFailed>());
  });

  const med = NotificationTarget(type: 'med', familyId: 'f1', id: 'm1');
  const medJson = '{"id":"m1","childId":"c1","name":"Ateş şurubu","minIntervalMinutes":360}';

  test('Verdim saves a dose without overriding the spacing rule', () async {
    final api = _Api(201, medJson);
    final client = ApiClient(_Tokens(), dio: Dio(BaseOptions(baseUrl: 'http://x'))..httpClientAdapter = api);

    expect(await runNotificationAction(client, giveMedicationAction, med), isA<ActionDone>());
    expect(api.calls.single, 'POST /api/v1/families/f1/medications/m1/doses {"givenAt":null,"note":null,"force":false}');
    expect(med.route, '/medications');
  });

  test('Verdim on a dose someone already gave is refused with who and when', () async {
    final api = _Api(409,
        '{"code":"medication.too_soon","lastDose":{"id":"d1","givenAt":"2026-11-23T11:05:00Z","givenByName":"Mehmet"},"nextAllowedAt":"2026-11-23T17:05:00Z"}');
    final client = ApiClient(_Tokens(), dio: Dio(BaseOptions(baseUrl: 'http://x'))..httpClientAdapter = api);

    final result = await runNotificationAction(client, giveMedicationAction, med);

    expect(result, isA<ActionDoseRefused>());
    expect((result as ActionDoseRefused).warning.lastDose.givenByName, 'Mehmet');
    expect(result.warning.isDailyLimit, isFalse);
  });

  test('a due push becomes a tray notification; a given push clears it', () async {
    final tray = _Tray();
    final due = {'kind': 'MedicationDue', 'familyId': 'f1', 'medicationId': 'm1', 'title': 'Ela: Ateş şurubu zamanı', 'body': 'Son doz: 14:05'};

    expect(await handleNotificationPush(due, tray, tr), isTrue);
    expect(tray.log, ['show med:m1 Ela: Ateş şurubu zamanı / Son doz: 14:05']);

    await handleNotificationPush({'kind': 'MedicationGiven', 'familyId': 'f1', 'medicationId': 'm1'}, tray, tr);
    expect(tray.log.last, 'cancel med:m1');

    expect(await handleNotificationPush({'kind': 'Message', 'familyId': 'f1'}, tray, tr), isFalse);
    expect(tray.log, hasLength(2));
  });

  test("a child request becomes Evet/Hayır in the tray; the other parent's answer clears it", () async {
    final tray = _Tray();
    final ask = {'kind': 'ChildAsk', 'familyId': 'f1', 'askId': 'a1', 'title': 'Ela bir şey istiyor', 'body': '🏠 Arkadaşıma gidebilir miyim? · Zeynep'};

    expect(await handleNotificationPush(ask, tray, tr), isTrue);
    expect(tray.log, ['ask ask:a1 Ela bir şey istiyor / 🏠 Arkadaşıma gidebilir miyim? · Zeynep']);

    expect(await handleNotificationPush({'kind': 'ChildAskAnswered', 'familyId': 'f1', 'askId': 'a1'}, tray, tr), isFalse,
        reason: 'the system shows "Ayşe onayladı"');
    expect(tray.log.last, 'cancel ask:a1');
    expect(const NotificationTarget(type: 'ask', familyId: 'f1', id: 'a1').route, '/asks');
  });

  test('Evet from the lock screen answers; second to answer gets a notice', () async {
    const ask = NotificationTarget(type: 'ask', familyId: 'f1', id: 'a1');
    final ok = _Api(200, '{"id":"a1","childId":"c1","childName":"Ela","emoji":"🏠","title":"x","status":"Yes","createdAt":"2026-11-25T12:00:00Z"}');
    final client = ApiClient(_Tokens(), dio: Dio(BaseOptions(baseUrl: 'http://x'))..httpClientAdapter = ok);
    expect(await runNotificationAction(client, askYesAction, ask), isA<ActionDone>());
    expect(ok.calls.single, 'POST /api/v1/families/f1/asks/a1/answer {"yes":true,"note":null}');

    final late = _Api(409, '{"code":"ask.already_answered","detail":"Ayşe already answered."}');
    final second = ApiClient(_Tokens(), dio: Dio(BaseOptions(baseUrl: 'http://x'))..httpClientAdapter = late);
    final result = await runNotificationAction(second, askNoAction, ask);
    expect(result, isA<ActionAskTaken>());
    expect(actionNotice(result, tr)!.title, 'İstek zaten yanıtlandı');
  });
}

void nowWidgetTests() {
  final tr = lookupAppLocalizations(const Locale('tr'));

  test('the Şu an widget gets every timer, texts, and its Durdur link is understood', () {
    final t = LiveTimer(
        type: 'study',
        familyId: 'f1',
        childId: 'c2',
        title: 'Can · kitap okuma',
        body: 'x',
        emoji: '📖',
        countingSince: DateTime(2026, 11, 23, 17, 47),
        until: DateTime(2026, 11, 23, 21));
    final data = nowWidgetData([t], tr);

    expect(data['now.title'], 'Şu an');
    expect(data['now.count'], '%d sayaç çalışıyor');
    final items = jsonDecode(data['now.items']!) as List;
    expect(items.single['since'], DateTime(2026, 11, 23, 17, 47).millisecondsSinceEpoch);

    final target = nowWidgetStopTarget(Uri.parse('hally://timer/stop?type=study&family=f1&child=c2'))!;
    expect((target.type, target.familyId, target.id), ('study', 'f1', 'c2'));
    expect(nowWidgetStopTarget(Uri.parse('hally://timer/stop?type=med&family=f1&child=c2')), isNull);
    expect(nowWidgetStopTarget(null), isNull);
    expect(jsonDecode(nowWidgetWithout(data['now.items']!, target)), isEmpty);
  });
}

class _Tray extends NoDeviceNotifications {
  final log = <String>[];

  @override
  Future<void> showMedicationDue(NotificationTarget target, String title, String body, AppLocalizations l10n) async =>
      log.add('show ${target.type}:${target.id} $title / $body');

  @override
  Future<void> showChildAsk(NotificationTarget target, String title, String body, AppLocalizations l10n) async =>
      log.add('ask ${target.type}:${target.id} $title / $body');

  @override
  Future<void> cancel(NotificationTarget target) async => log.add('cancel ${target.type}:${target.id}');
}
