import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/features/child_mode/child_mode_repository.dart';
import 'package:hally/features/child_mode/kid_screens.dart';
import 'package:hally/features/goal/family_goal.dart';
import 'package:hally/features/goal/goal_widgets.dart';
import 'package:hally/features/notifications/push.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

FamilyGoal _goal({int total = 86, int target = 120}) => FamilyGoal(
      id: 'g1',
      weekEnd: DateTime(2026, 11, 29),
      daysLeft: 3,
      rewardTitle: 'Cumartesi piknik',
      rewardEmoji: '🧺',
      target: target,
      total: total,
      repeat: true,
      contributors: const [
        GoalContributor(kind: 'Child', id: 'c1', name: 'Ela', color: 'sky', cherries: 32),
        GoalContributor(kind: 'Child', id: 'c2', name: 'Can', color: 'mint', cherries: 22),
        GoalContributor(kind: 'Adult', id: 'u1', name: 'Ayşe', cherries: 18),
        GoalContributor(kind: 'Adult', id: 'u2', name: 'Mehmet', cherries: 14),
      ],
    );

class _Repo implements FamilyGoalRepository {
  final calls = <String>[];
  var state = const FamilyGoalState(lastWeekTotal: 104, suggestedTarget: 120);

  @override
  Future<FamilyGoalState> load(String familyId) async => state;

  @override
  Future<FamilyGoalState> set(String familyId, {required String rewardTitle, required String rewardEmoji, required int target, required bool repeat}) async {
    calls.add('set $rewardEmoji $rewardTitle $target $repeat');
    state = FamilyGoalState(goal: _goal(total: 0, target: target), lastWeekTotal: 104, suggestedTarget: 120);
    return state;
  }

  @override
  Future<FamilyGoalState> end(String familyId) async {
    calls.add('end');
    state = const FamilyGoalState(lastWeekTotal: 104, suggestedTarget: 120);
    return state;
  }
}

class _KidApi implements ChildApi {
  @override
  Future<ChildHome> home() async => const ChildHome(
        childId: 'c1',
        firstName: 'Ela',
        color: 'sky',
        familyName: 'Yılmaz',
        balance: 34,
        weekCherries: 21,
        streakDays: 2,
        nextBonusIn: 5,
        today: [],
        rewards: [],
        screen: ChildScreen(goalMinutes: 60, limitMinutes: 60, usedSeconds: 60),
        todayMood: 'Good',
      );

  @override
  Future<FamilyGoalState> goal() async => FamilyGoalState(goal: _goal());

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

Widget _app(Widget home, {FamilyGoalRepository? repo, ChildApi? kid}) => ProviderScope(
      overrides: [
        if (repo != null) familyGoalRepositoryProvider.overrideWithValue(repo),
        if (kid != null) childApiProvider.overrideWithValue(kid),
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
  test('the goal notification opens the goal', () {
    expect(pushRoute({'kind': 'FamilyGoalReached'}), '/family-goal');
  });

  testWidgets('a parent sets the weekly goal from the suggestion and ends it', (tester) async {
    _phone(tester);
    final repo = _Repo();
    await tester.pumpWidget(_app(const FamilyGoalScreen(familyId: 'f1'), repo: repo));
    await tester.pumpAndSettle();

    expect(find.text('Bu hafta hedef yok'), findsOneWidget);
    await tester.tap(find.byKey(const Key('goal.start')));
    await tester.pumpAndSettle();

    expect(find.text('Geçen hafta 104 toplandı'), findsOneWidget);
    expect(find.byKey(const Key('goal.target.80')), findsOneWidget);
    expect(find.byKey(const Key('goal.target.160')), findsOneWidget);
    expect(tester.widget<ChoiceChip>(find.byKey(const Key('goal.target.120'))).selected, isTrue);
    await tester.tap(find.byKey(const Key('goal.reward.🍕')));
    await tester.tap(find.byKey(const Key('goal.target.160')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('goal.save')));
    await tester.tap(find.byKey(const Key('goal.save')));
    await tester.pumpAndSettle();

    expect(repo.calls, ['set 🍕 Pizza akşamı 160 true']);
    expect(find.text('BU HAFTANIN HEDEFİ'), findsOneWidget);
    expect(find.text('3 gün kaldı'), findsOneWidget);
    expect(find.text('Kim ne kattı'), findsOneWidget);

    await tester.tap(find.byKey(const Key('goal.menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('goal.end')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('goal.end.confirm')));
    await tester.pumpAndSettle();
    expect(repo.calls.last, 'end');
    expect(find.text('Bu hafta hedef yok'), findsOneWidget);
  });

  testWidgets('a custom reward can be written', (tester) async {
    _phone(tester);
    final repo = _Repo();
    await tester.pumpWidget(_app(const FamilyGoalScreen(familyId: 'f1'), repo: repo));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('goal.start')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('goal.reward.own')), 'Hayvanat bahçesi');
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('goal.save')));
    await tester.tap(find.byKey(const Key('goal.save')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['set 🎁 Hayvanat bahçesi 120 true']);
  });

  testWidgets('the child sees the shared goal in the jar tab, everyone listed without ranking', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(const KidShell(), kid: _KidApi()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('kid.tab.jar')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('goal.card')), findsOneWidget);
    expect(find.text('34 kiraz daha. Birlikte yaparız! 💪'), findsOneWidget);
    await tester.tap(find.byKey(const Key('goal.card')));
    await tester.pumpAndSettle();

    expect(find.text('🧺 Cumartesi piknik'), findsOneWidget);
    expect(find.byKey(const Key('goal.total')), findsOneWidget);
    final names = [
      for (final id in ['c1', 'c2', 'u1', 'u2']) tester.getTopLeft(find.byKey(Key('goal.who.$id'))).dy
    ];
    expect(names, [...names]..sort(), reason: 'children first, then parents, in the family order');
    expect(find.text('Kirazlar kendi kavanozundan eksilmez; aile görevine ayrıca sayılır.'), findsOneWidget);
  });

  testWidgets('a reached goal says so', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(Scaffold(body: GoalBody(goal: _goal(total: 130)))));
    await tester.pumpAndSettle();
    expect(find.text('🎉 Hedef tamam! Ödülün tadını çıkarın.'), findsOneWidget);
  });
}
