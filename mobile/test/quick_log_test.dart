import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/auth/auth_repository.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/features/capture/quick_log.dart';
import 'package:hally/features/family/family_repository.dart';
import 'package:hally/features/home/live_now.dart';
import 'package:hally/features/messages/chat_realtime.dart';
import 'package:hally/features/screen_time/screen_time_repository.dart';
import 'package:hally/features/sleep/sleep_repository.dart';
import 'package:hally/features/study/study_repository.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

const _me = Me(id: 'u1', displayName: 'Ayşe', locale: 'tr', families: [FamilyRef(id: 'f1', name: 'Yılmaz')]);
final _deniz = ChildProfile(id: 'c1', firstName: 'Deniz', birthYear: DateTime.now().year - 1, color: 'sky');
final _ela = ChildProfile(id: 'c2', firstName: 'Ela', birthYear: DateTime.now().year - 8, color: 'mint');

class _FakeSleep implements SleepRepository {
  final calls = <String>[];
  SleepEntry? open;

  @override
  Future<List<ChildSleepStatus>> status(String familyId) async => [ChildSleepStatus(childId: 'c1', asleep: open)];

  @override
  Future<ChildSleepStatus> asleep(String familyId, String childId, {DateTime? at}) async {
    calls.add('asleep $childId');
    open = SleepEntry(id: 's1', childId: childId, kind: 'Nap', startedAt: DateTime.now());
    return ChildSleepStatus(childId: childId, asleep: open);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _FakeScreen implements ScreenTimeRepository {
  @override
  Future<List<ChildScreenTime>> today(String familyId) async => [
        ChildScreenTime(childId: 'c2', todaySeconds: 25 * 60, receivedAt: DateTime.now(), dailyGoalMinutes: 60, runningSince: DateTime.now()),
      ];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _FakeStudy implements StudyRepository {
  @override
  Future<List<ChildStudyStatus>> today(String familyId) async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

Widget _app(_FakeSleep sleep, Widget Function(void Function({String? message, String? route}) done) body) => ProviderScope(
      overrides: [
        meProvider.overrideWith((ref) async => _me),
        chatRealtimeProvider.overrideWithValue(NoChatRealtime()),
        sleepRepositoryProvider.overrideWithValue(sleep),
        screenTimeRepositoryProvider.overrideWithValue(_FakeScreen()),
        studyRepositoryProvider.overrideWithValue(_FakeStudy()),
        familyProvider.overrideWith((ref, id) async => FamilyDetails(id: 'f1', name: 'Yılmaz', timeZoneId: 'Europe/Istanbul', members: const [], children: [_deniz, _ela])),
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
        home: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: body(({message, route}) {}))),
      ),
    );

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('quick log starts sleep for a baby in one tap and fits the age', (tester) async {
    _phone(tester);
    final sleep = _FakeSleep();
    final done = <String?>[];
    await tester.pumpWidget(_app(sleep, (_) => QuickLog(familyId: 'f1', onDone: ({message, route}) => done.add(message ?? route))));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('quick.feeding')), findsOneWidget);
    expect(find.byKey(const Key('quick.study')), findsNothing);
    await tester.tap(find.byKey(const Key('quick.sleep')));
    await tester.pumpAndSettle();
    expect(sleep.calls, ['asleep c1']);
    expect(done, ['Uyku başladı: Deniz']);

    await tester.tap(find.byKey(const Key('quick.child.c2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quick.study')), findsOneWidget);
    expect(find.text('Ekran süresini durdur'), findsOneWidget);
    await tester.tap(find.byKey(const Key('quick.stars')));
    expect(done.last, '/stars');
  });

  testWidgets('right-now strip shows who is asleep and running screen time', (tester) async {
    _phone(tester);
    final sleep = _FakeSleep()..open = SleepEntry(id: 's1', childId: 'c1', kind: 'Nap', startedAt: DateTime.now().subtract(const Duration(minutes: 72)));
    await tester.pumpWidget(_app(sleep, (_) => const LiveNowStrip(familyId: 'f1')));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.text('Şu an'), findsOneWidget);
    expect(find.text('Deniz uyuyor'), findsOneWidget);
    expect(find.text('1 sa 12 dk'), findsOneWidget);
    expect(find.text('Ela · ekran'), findsOneWidget);
    expect(find.text('25 / 60 dk'), findsOneWidget);
  });
}
