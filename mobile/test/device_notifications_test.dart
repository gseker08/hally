import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/api/api_client.dart';
import 'package:hally/core/auth/token_storage.dart';
import 'package:hally/features/notifications/device_notifications.dart';
import 'package:hally/features/screen_time/screen_time_repository.dart';
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

  test('only timers this user started get a notification, counting today\'s total', () {
    final notices = screenTimeNotices(
      familyId: 'f1',
      userId: 'me',
      statuses: {
        'c1': status('c1', by: 'me', seconds: 1500, goal: 60),
        'c2': status('c2', by: 'partner'),
        'c3': status('c3'),
      },
      childNames: {'c1': 'Ada', 'c2': 'Can'},
      l10n: tr,
      now: now,
    );

    final n = notices.single;
    expect(n.childId, 'c1');
    expect(n.title, 'Ada · ekran süresi');
    expect(n.body, 'Günlük hedef: 60 dk');
    expect(n.countingSince, now.subtract(const Duration(seconds: 1500)));
    expect(n.until, now.add(const Duration(hours: 7, minutes: 50)));
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

    final ok = await runNotificationAction(client, stopScreenTimeAction, const NotificationTarget(type: 'screen', familyId: 'f1', id: 'c1'));

    expect(ok, isA<ActionDone>());
    expect(api.calls, ['POST /api/v1/families/f1/children/c1/screen-time/stop']);
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
}

class _Tray extends NoDeviceNotifications {
  final log = <String>[];

  @override
  Future<void> showMedicationDue(NotificationTarget target, String title, String body, AppLocalizations l10n) async =>
      log.add('show ${target.type}:${target.id} $title / $body');

  @override
  Future<void> cancel(NotificationTarget target) async => log.add('cancel ${target.type}:${target.id}');
}
