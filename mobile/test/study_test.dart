import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/auth/auth_repository.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/features/family/family_repository.dart';
import 'package:hally/features/messages/chat_realtime.dart';
import 'package:hally/features/notifications/push.dart';
import 'package:hally/features/study/study_repository.dart';
import 'package:hally/features/study/study_screen.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

const _me = Me(id: 'u1', displayName: 'Ayşe', locale: 'tr', families: [FamilyRef(id: 'f1', name: 'Yılmaz')]);
const _ela = ChildProfile(id: 'c1', firstName: 'Ela', color: 'mint');

class _FakeStudy implements StudyRepository {
  final calls = <String>[];
  int? goal = 30;
  int seconds = 1200;
  String? running;
  DateTime? since;
  int streak = 3;
  final entries = <StudyEntry>[];

  ChildStudyStatus get _status => ChildStudyStatus(
        childId: 'c1',
        dailyGoalMinutes: goal,
        todaySeconds: seconds,
        homeworkSeconds: seconds,
        runningKind: running,
        runningSince: since,
        runningUntil: since?.add(const Duration(hours: 4)),
        streak: streak,
      );

  @override
  Future<List<ChildStudyStatus>> today(String familyId) async => [_status];

  @override
  Future<StudyHistory> history(String familyId, String childId) async => StudyHistory(
        dailyGoalMinutes: goal,
        days: [for (var i = 0; i < 7; i++) StudyDay(date: DateTime(2026, 11, 17 + i), homeworkSeconds: 1500, readingSeconds: i.isEven ? 600 : 0, goalMet: i.isEven)],
        entries: entries,
      );

  @override
  Future<ChildStudyStatus> start(String familyId, String childId, String kind) async {
    calls.add('start $kind');
    running = kind;
    since = DateTime.now().subtract(const Duration(minutes: 2));
    return _status;
  }

  @override
  Future<ChildStudyStatus> stop(String familyId, String childId, {String? note}) async {
    calls.add('stop');
    seconds += 120;
    running = null;
    since = null;
    return _status;
  }

  @override
  Future<ChildStudyStatus> add(String familyId, String childId, {required String kind, required int minutes, String? note}) async {
    calls.add('add $kind $minutes ${note ?? ''}'.trim());
    return _status;
  }

  @override
  Future<ChildStudyStatus> delete(String familyId, String childId, String entryId) async {
    calls.add('delete $entryId');
    entries.removeWhere((e) => e.id == entryId);
    return _status;
  }

  @override
  Future<ChildStudyStatus> setGoal(String familyId, String childId, int? minutes) async {
    calls.add('goal $minutes');
    goal = minutes;
    return _status;
  }
}

Widget _app(_FakeStudy repo) => ProviderScope(
      overrides: [
        meProvider.overrideWith((ref) async => _me),
        studyRepositoryProvider.overrideWithValue(repo),
        chatRealtimeProvider.overrideWithValue(NoChatRealtime()),
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
        home: const StudyScreen(),
      ),
    );

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  test('a running timer counts on locally but not past its cap', () {
    final received = DateTime(2026, 11, 23, 17);
    final s = ChildStudyStatus(
      childId: 'c1',
      dailyGoalMinutes: 30,
      todaySeconds: 1500,
      runningKind: 'Reading',
      runningSince: received.subtract(const Duration(minutes: 5)),
      runningUntil: received.add(const Duration(minutes: 10)),
      receivedAt: received,
    );
    expect(s.secondsAt(received.add(const Duration(minutes: 4))), 1740);
    expect(s.goalMetAt(received.add(const Duration(minutes: 5))), isTrue);
    expect(s.secondsAt(received.add(const Duration(hours: 2))), 2100);
  });

  test('the goal push opens the homework page', () {
    expect(pushRoute({'kind': 'StudyGoal'}), '/study');
  });

  testWidgets('start reading, see it run, stop; streak and goal shown', (tester) async {
    _phone(tester);
    final repo = _FakeStudy();
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();
    expect(find.text('Bugün 20 dk / hedef 30 dk'), findsOneWidget);
    expect(find.text('Seri: 3 gün'), findsOneWidget);

    await tester.tap(find.byKey(const Key('study.start.Reading.c1')));
    await tester.pump();
    await tester.pump();
    expect(repo.calls, ['start Reading']);
    expect(find.textContaining('Okuma · 02:0'), findsOneWidget);

    await tester.tap(find.byKey(const Key('study.stop.c1')));
    await tester.pump();
    await tester.pump();
    expect(repo.calls, ['start Reading', 'stop']);
    expect(find.text('Bugün 22 dk / hedef 30 dk'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the week sets a goal, adds time and deletes an entry', (tester) async {
    _phone(tester);
    final now = DateTime.now();
    final repo = _FakeStudy()..entries.add(StudyEntry(id: 'e1', kind: 'Reading', startedAt: now.subtract(const Duration(minutes: 20)), endedAt: now, seconds: 1200, note: 'Küçük Prens'));
    await tester.pumpWidget(_app(repo));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('study.line.c1')));
    await tester.pumpAndSettle();
    expect(find.text('Günlük hedef: 30 dk'), findsOneWidget);
    expect(find.textContaining('Küçük Prens'), findsOneWidget);

    await tester.tap(find.byKey(const Key('study.goal')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('study.goal.45')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['goal 45']);
    expect(find.text('Günlük hedef: 45 dk'), findsOneWidget);

    await tester.tap(find.byKey(const Key('study.delete.e1')));
    await tester.pumpAndSettle();
    expect(repo.calls.last, 'delete e1');

    await tester.tap(find.byKey(const Key('study.add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('study.minutes.plus')));
    await tester.enterText(find.byKey(const Key('study.note')), 'Matematik');
    await tester.tap(find.byKey(const Key('study.save')));
    await tester.pumpAndSettle();
    expect(repo.calls.last, 'add Homework 25 Matematik');
    await tester.pumpWidget(const SizedBox());
  });
}
