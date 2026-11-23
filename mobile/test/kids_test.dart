import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/auth/auth_repository.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/features/family/family_repository.dart';
import 'package:hally/features/insights/insights_repository.dart';
import 'package:hally/features/kids/kids_screen.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

const _me = Me(id: 'u1', displayName: 'Ayşe', locale: 'tr', families: [FamilyRef(id: 'f1', name: 'Yılmaz')]);
const _ela = ChildProfile(id: 'c1', firstName: 'Ela', birthYear: 2018, color: 'mint');
const _deniz = ChildProfile(id: 'c2', firstName: 'Deniz', birthYear: 2025, color: 'sky');
final _today = DateTime(2026, 11, 23);

class _FakeInsights implements InsightsRepository {
  final children = <String>[];

  @override
  Future<ChildInsights> insights(String familyId, String childId, {required DateTime from, required DateTime to}) async {
    children.add(childId);
    return ChildInsights(
      childId: childId,
      from: from,
      to: to,
      today: _today,
      screenGoalMinutes: 60,
      studyGoalMinutes: 30,
      days: [InsightDay(date: _today, screenMinutes: 25, homeworkMinutes: 15, readingMinutes: 5, napMinutes: 70, feeds: 4, doses: 1, habitsDone: 2, habitsScheduled: 3)],
      habits: const [HabitInsight(id: 'h1', title: 'Diş', streak: 6)],
      starBalance: 42,
      health: const HealthSnapshot(vaccinesDueSoon: 1),
    );
  }
}

Widget _app(_FakeInsights repo, {List<ChildProfile> children = const [_ela, _deniz]}) => ProviderScope(
      overrides: [
        meProvider.overrideWith((ref) async => _me),
        insightsRepositoryProvider.overrideWithValue(repo),
        familyProvider.overrideWith((ref, id) async => FamilyDetails(id: 'f1', name: 'Yılmaz', timeZoneId: 'Europe/Istanbul', members: const [], children: children)),
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
        home: KidsScreen(now: _today),
      ),
    );

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  test('trackers follow the child age', () {
    expect(trackersForAge(null), Tracker.values.toSet());
    expect(trackersForAge(1), {Tracker.sleep, Tracker.medications, Tracker.health, Tracker.habits, Tracker.feeding});
    expect(trackersForAge(8).containsAll([Tracker.study, Tracker.stars, Tracker.screenTime]), isTrue);
    expect(trackersForAge(8).contains(Tracker.feeding), isFalse);
  });

  testWidgets('a school-age child sees growth first with live values', (tester) async {
    _phone(tester);
    final repo = _FakeInsights();
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();

    expect(find.text('Bugün · Ela'), findsOneWidget);
    expect(find.text('8 yaş'), findsOneWidget);
    expect(find.text('Gelişim'), findsOneWidget);
    expect(find.byKey(const Key('kids.tile.study')), findsOneWidget);
    expect(find.text('42'), findsOneWidget);
    expect(find.text('6 gün seri'), findsOneWidget);
    expect(find.byKey(const Key('kids.tile.feeding')), findsNothing);
    expect(repo.children, ['c1']);

    await tester.ensureVisible(find.byKey(const Key('kids.more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('kids.more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('kids.tile.feeding'), skipOffstage: false), findsOneWidget);
  });

  testWidgets('switching to a baby shows care trackers', (tester) async {
    _phone(tester);
    final repo = _FakeInsights();
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('kids.child.c2')));
    await tester.pumpAndSettle();
    expect(find.text('Bugün · Deniz'), findsOneWidget);
    expect(find.byKey(const Key('kids.tile.feeding')), findsOneWidget);
    expect(find.text('4 öğün'), findsWidgets);
    expect(find.byKey(const Key('kids.tile.study')), findsNothing);
    expect(repo.children, ['c1', 'c2']);
  });

  testWidgets('no children yet asks to add one', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(_FakeInsights(), children: const []));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('kids.addFirst')), findsOneWidget);
  });
}
