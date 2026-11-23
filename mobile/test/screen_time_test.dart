import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/auth/auth_repository.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/features/family/family_repository.dart';
import 'package:hally/features/messages/chat_realtime.dart';
import 'package:hally/features/notifications/push.dart';
import 'package:hally/features/screen_time/screen_time_repository.dart';
import 'package:hally/features/screen_time/screen_time_screen.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

const _me = Me(id: 'u1', displayName: 'Ayşe', locale: 'tr', families: [FamilyRef(id: 'f1', name: 'Yılmaz')]);
const _ela = ChildProfile(id: 'c1', firstName: 'Ela', color: 'sky');

class _FakeScreenTime implements ScreenTimeRepository {
  final calls = <String>[];
  ChildScreenTime state = ChildScreenTime(childId: 'c1', todaySeconds: 600, dailyGoalMinutes: 60, receivedAt: DateTime.now());

  ChildScreenTime _with({bool? running, int? goal, int add = 0}) {
    final r = running ?? state.isRunning;
    final now = DateTime.now().toUtc();
    return state = ChildScreenTime(
      childId: 'c1',
      todaySeconds: state.todaySeconds + add,
      dailyGoalMinutes: goal ?? state.dailyGoalMinutes,
      runningSince: r ? now : null,
      runningUntil: r ? now.add(const Duration(hours: 8)) : null,
      asOf: now,
      startedByUserId: r ? 'u1' : null,
      startedByName: r ? 'Ayşe' : null,
      receivedAt: DateTime.now(),
    );
  }

  @override
  Future<List<ChildScreenTime>> today(String familyId) async => [state];

  @override
  Future<ScreenTimeWeek> week(String familyId, {DateTime? start}) async => ScreenTimeWeek(start: DateTime(2026, 11, 23), children: [
        ChildScreenWeek(childId: 'c1', dailyGoalMinutes: 60, dailySeconds: const [600, 4000, 0, 0, 0, 0, 0], totalSeconds: 4600, averageSeconds: 2300, daysOverGoal: 1),
      ]);

  @override
  Future<ChildScreenTime> start(String familyId, String childId) async {
    calls.add('start $childId');
    return _with(running: true);
  }

  @override
  Future<ChildScreenTime> stop(String familyId, String childId) async {
    calls.add('stop $childId');
    return _with(running: false);
  }

  @override
  Future<ChildScreenTime> addMinutes(String familyId, String childId, int minutes) async {
    calls.add('add $minutes');
    return _with(add: minutes * 60);
  }

  @override
  Future<ChildScreenTime> setGoal(String familyId, String childId, int? dailyMinutes) async {
    calls.add('goal $dailyMinutes');
    return _with(goal: dailyMinutes);
  }
}

class _FakeRealtime implements ChatRealtime {
  final screen = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<ChatMessageEvent> get events => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get medicationEvents => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get shoppingEvents => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get screenTimeEvents => screen.stream;

  @override
  bool get isConnected => true;

  @override
  Future<void> dispose() => screen.close();
}

Widget _app(Widget home, _FakeScreenTime repo, _FakeRealtime realtime) => ProviderScope(
      overrides: [
        meProvider.overrideWith((ref) async => _me),
        screenTimeRepositoryProvider.overrideWithValue(repo),
        chatRealtimeProvider.overrideWithValue(realtime),
        familyProvider.overrideWith((ref, id) async => const FamilyDetails(id: 'f1', name: 'Yılmaz', timeZoneId: 'Europe/Istanbul', members: [], children: [_ela])),
      ],
      child: MaterialApp(
        theme: buildHallyTheme(Brightness.light),
        locale: const Locale('tr'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: home,
      ),
    );

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  test('durations read naturally in both languages', () {
    expect(formatScreenDuration(12 * 60, turkish: true), '12 dk');
    expect(formatScreenDuration(3600, turkish: true), '1 sa');
    expect(formatScreenDuration(3900, turkish: false), '1 h 05 min');
    expect(formatScreenDuration(3725, turkish: true, withSeconds: true), '1:02:05');
    expect(formatScreenDuration(65, turkish: true, withSeconds: true), '01:05');
  });

  test('a running timer counts on locally but not past its 8 hour cap', () {
    final received = DateTime(2026, 11, 23, 10);
    final asOf = DateTime.utc(2026, 11, 23, 7);
    final t = ChildScreenTime(
      childId: 'c1',
      todaySeconds: 100,
      runningSince: asOf.subtract(const Duration(hours: 7, minutes: 59)),
      runningUntil: asOf.add(const Duration(minutes: 1)),
      asOf: asOf,
      receivedAt: received,
    );
    expect(t.secondsAt(received.add(const Duration(seconds: 30))), 130);
    expect(t.secondsAt(received.add(const Duration(hours: 1))), 160);
  });

  test('the goal push opens the screen time page', () {
    expect(pushRoute({'kind': 'ScreenTimeGoal', 'targetId': 'c1'}), '/screen-time');
  });

  testWidgets('start and stop from the child row, and the other parent\'s tap arrives live', (tester) async {
    _phone(tester);
    final repo = _FakeScreenTime();
    final realtime = _FakeRealtime();
    await tester.pumpWidget(_app(const Scaffold(body: ScreenTimeCard(familyId: 'f1', children: [_ela])), repo, realtime));
    await tester.pump();
    await tester.pump();

    expect(find.text('Bugün 10 dk / 1 sa'), findsOneWidget);
    await tester.tap(find.byKey(const Key('screenTime.start.c1')));
    await tester.pump();
    expect(repo.calls, ['start c1']);
    expect(find.byKey(const Key('screenTime.stop.c1')), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('Bugün 10:0'), findsOneWidget);

    await tester.tap(find.byKey(const Key('screenTime.stop.c1')));
    await tester.pump();
    expect(repo.calls.last, 'stop c1');

    // The partner starts the timer on their phone.
    final now = DateTime.now().toUtc();
    realtime.screen.add({
      'familyId': 'f1',
      'status': {
        'childId': 'c1',
        'dailyGoalMinutes': 60,
        'todaySeconds': 3700,
        'runningSince': now.toIso8601String(),
        'runningUntil': now.add(const Duration(hours: 8)).toIso8601String(),
        'asOf': now.toIso8601String(),
        'startedByUserId': 'u2',
        'startedByName': 'Mehmet',
      },
    });
    await tester.pump();
    await tester.pump();
    expect(find.text('Mehmet başlattı'), findsOneWidget);
    expect(find.text('Günlük hedef doldu'), findsOneWidget);
    expect(find.byKey(const Key('screenTime.stop.c1')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the page shows the week and sets a goal and extra minutes', (tester) async {
    _phone(tester);
    final repo = _FakeScreenTime();
    await tester.pumpWidget(_app(const ScreenTimeScreen(), repo, _FakeRealtime()));
    await tester.pumpAndSettle();

    expect(find.text('Toplam 1 sa 16 dk · günlük ortalama 38 dk'), findsOneWidget);
    expect(find.text('1 gün hedef aşıldı'), findsOneWidget);

    await tester.tap(find.byKey(const Key('screenTime.goal.c1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('screenTime.goal.90')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['goal 90']);
    expect(find.text('Bugün 10 dk / 1 sa 30 dk'), findsOneWidget);

    await tester.tap(find.byKey(const Key('screenTime.add.c1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('screenTime.add.30')));
    await tester.pumpAndSettle();
    expect(repo.calls.last, 'add 30');
    expect(find.text('Bugün 40 dk / 1 sa 30 dk'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
