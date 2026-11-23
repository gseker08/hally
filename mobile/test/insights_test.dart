import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/auth/auth_repository.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/features/family/family_repository.dart';
import 'package:hally/features/insights/insights_repository.dart';
import 'package:hally/features/insights/insights_screen.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

const _me = Me(id: 'u1', displayName: 'Ayşe', locale: 'tr', families: [FamilyRef(id: 'f1', name: 'Yılmaz')]);
const _ela = ChildProfile(id: 'c1', firstName: 'Ela', color: 'mint');
final _today = DateTime(2026, 11, 23);

class _FakeInsights implements InsightsRepository {
  final calls = <String>[];
  bool empty = false;

  @override
  Future<ChildInsights> insights(String familyId, String childId, {required DateTime from, required DateTime to}) async {
    calls.add('${insightsDay(from)} ${insightsDay(to)}');
    final days = [
      for (var d = from; !d.isAfter(to); d = d.add(const Duration(days: 1)))
        empty
            ? InsightDay(date: d)
            : InsightDay(date: d, screenMinutes: d == _today ? 75 : 30, homeworkMinutes: 20, readingMinutes: 10, nightSleepMinutes: 600, habitsDone: 1, habitsScheduled: 1),
    ];
    return ChildInsights(
      childId: childId,
      from: from,
      to: to,
      today: _today,
      screenGoalMinutes: empty ? null : 60,
      days: days,
      habits: empty ? const [] : const [HabitInsight(id: 'h1', title: 'Diş fırçalama', streak: 4, best: 6, done: 1, scheduled: 1)],
      health: empty ? const HealthSnapshot() : const HealthSnapshot(heightCm: 102, hasAllergies: true, vaccinesOverdue: 1),
    );
  }
}

Widget _app(_FakeInsights repo) => ProviderScope(
      overrides: [
        meProvider.overrideWith((ref) async => _me),
        insightsRepositoryProvider.overrideWithValue(repo),
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
        home: InsightsScreen(childId: 'c1', today: _today),
      ),
    );

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('shows today against the goals, then the week', (tester) async {
    _phone(tester);
    final repo = _FakeInsights();
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();
    expect(find.text('Ela · Analiz'), findsOneWidget);
    expect(repo.calls, ['2026-11-23 2026-11-23']);
    expect(find.text('Bugün'), findsOneWidget);
    expect(find.text('1 sa 15 dk'), findsOneWidget);
    expect(find.text('Hedef 1 sa 00 dk, aşıldı'), findsOneWidget);
    expect(find.text('Ödev 20 dk · Okuma 10 dk'), findsOneWidget);

    await tester.tap(find.byKey(const Key('insights.weekly')));
    await tester.pumpAndSettle();
    expect(repo.calls.last, '2026-11-17 2026-11-23');
    expect(find.text('Hedef 1 sa 00 dk · 1 gün aşıldı'), findsOneWidget);

    await tester.tap(find.byKey(const Key('insights.prev')));
    await tester.pumpAndSettle();
    expect(repo.calls.last, '2026-11-10 2026-11-16');
    expect(find.text('Hedef 1 sa 00 dk · 0 gün aşıldı'), findsOneWidget);

    await tester.scrollUntilVisible(find.byKey(const Key('insights.health')), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('1 aşı gecikti'), findsOneWidget);
    expect(find.text('Diş fırçalama'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('says so when nothing is logged', (tester) async {
    _phone(tester);
    final repo = _FakeInsights()..empty = true;
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('insights.empty')), findsOneWidget);
    expect(find.byKey(const Key('insights.next')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
