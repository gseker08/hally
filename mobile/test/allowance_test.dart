import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/features/allowance/allowance.dart';
import 'package:hally/features/allowance/allowance_screens.dart';
import 'package:hally/features/child_mode/child_mode_repository.dart';
import 'package:hally/features/notifications/push.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

class _KidApi implements ChildApi {
  ChildSavings current = ChildSavings(
    balance: 186,
    weeksToGoal: 4,
    goal: const SavingsGoal(title: 'Bisiklet', emoji: '🚲', cherries: 300),
    recent: [
      LedgerLine(kind: 'Chore', title: 'Odanı topla', points: 3, day: DateTime.now()),
      LedgerLine(kind: 'Allowance', title: 'weekly', points: 20, day: DateTime.now().subtract(const Duration(days: 1))),
      LedgerLine(kind: 'Allowance', title: 'converted', points: -50, day: DateTime.now().subtract(const Duration(days: 8))),
    ],
  );
  final calls = <String>[];

  @override
  Future<ChildSavings> savings() async => current;

  @override
  Future<ChildSavings> setSavingsGoal(SavingsGoal? goal) async {
    calls.add(goal == null ? 'clear' : '${goal.emoji} ${goal.title} ${goal.cherries}');
    current = ChildSavings(balance: current.balance, goal: goal, recent: current.recent);
    return current;
  }

  @override
  Future<ChildSavings> convert(int cherries) async {
    calls.add('convert $cherries');
    current = ChildSavings(
      balance: current.balance,
      goal: current.goal,
      recent: current.recent,
      pending: AllowanceRequestItem(
          id: 'r1', childId: 'c1', childName: 'Ela', cherries: cherries, amount: cherries / 2, status: AllowanceStatus.pending, createdAt: DateTime.now()),
    );
    return current;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Repo implements AllowanceRepository {
  AllowanceState state = AllowanceState(
    balance: 186,
    goal: const SavingsGoal(title: 'Bisiklet', emoji: '🚲', cherries: 300),
    requests: [
      AllowanceRequestItem(id: 'r1', childId: 'c1', childName: 'Ela', cherries: 40, amount: 20, status: AllowanceStatus.pending, createdAt: DateTime.now())
    ],
  );
  final calls = <String>[];

  @override
  Future<AllowanceState> load(String familyId, String childId) async => state;

  @override
  Future<AllowanceState> save(String familyId, String childId, AllowanceSettings settings) async {
    calls.add('save ${settings.rateCherries}=${settings.rateAmount} weekly ${settings.weeklyCherries} expenses ${settings.addToExpenses}');
    state = AllowanceState(settings: settings, goal: state.goal, balance: state.balance, requests: state.requests);
    return state;
  }

  @override
  Future<List<AllowanceRequestItem>> pending(String familyId) async => state.requests.where((r) => r.isPending).toList();

  @override
  Future<AllowanceRequestItem> decide(String familyId, String requestId, {required bool paid}) async {
    calls.add('decide $requestId $paid');
    final r = state.requests.single;
    final done = AllowanceRequestItem(
        id: r.id,
        childId: r.childId,
        childName: r.childName,
        cherries: r.cherries,
        amount: r.amount,
        status: paid ? AllowanceStatus.paid : AllowanceStatus.declined,
        createdAt: r.createdAt);
    state = AllowanceState(settings: state.settings, goal: state.goal, balance: state.balance - (paid ? r.cherries : 0), requests: [done]);
    return done;
  }
}

Widget _app(Widget home, {ChildApi? kid, AllowanceRepository? repo}) => ProviderScope(
      overrides: [
        if (kid != null) childApiProvider.overrideWithValue(kid),
        if (repo != null) allowanceRepositoryProvider.overrideWithValue(repo),
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
  tester.view.physicalSize = const Size(1080, 2600);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('the child sees the goal, the estimate and recent lines, and asks to convert', (tester) async {
    _phone(tester);
    final api = _KidApi();
    await tester.pumpWidget(_app(const Scaffold(body: SingleChildScrollView(child: KidSavingsSection())), kid: api));
    await tester.pumpAndSettle();

    expect(find.text('Bisiklet'), findsOneWidget);
    expect(find.text('186 / 300 kiraz'), findsOneWidget);
    expect(find.text('Böyle devam edersen 4 hafta sonra 🎉'), findsOneWidget);
    expect(find.text('10 kiraz = 5 ₺ · annen ya da baban onaylar'), findsOneWidget);
    expect(find.text('Odanı topla'), findsOneWidget);
    expect(find.text('Haftalık harçlık'), findsOneWidget);
    expect(find.text('Harçlığa çevrildi'), findsOneWidget);
    expect(find.text('−50'), findsOneWidget);
    expect(find.text('Dün'), findsOneWidget);

    await tester.tap(find.byKey(const Key('savings.convert')));
    await tester.pumpAndSettle();
    expect(find.text('= 5 ₺'), findsOneWidget);
    await tester.tap(find.byKey(const Key('convert.more')));
    await tester.tap(find.byKey(const Key('convert.more')));
    await tester.tap(find.byKey(const Key('convert.more')));
    await tester.pump();
    expect(find.text('= 20 ₺'), findsOneWidget);
    await tester.tap(find.byKey(const Key('convert.send')));
    await tester.pumpAndSettle();

    expect(api.calls, ['convert 40']);
    expect(find.text('40 kiraz = 20 ₺ · onay bekliyor'), findsOneWidget);
    expect(find.byKey(const Key('savings.convert')), findsNothing);
  });

  testWidgets('the child picks a new goal or removes it', (tester) async {
    _phone(tester);
    final api = _KidApi()..current = const ChildSavings(balance: 12);
    await tester.pumpWidget(_app(const Scaffold(body: SingleChildScrollView(child: KidSavingsSection())), kid: api));
    await tester.pumpAndSettle();

    // 12 cherries: one step of 10 can convert; no goal yet.
    await tester.tap(find.byKey(const Key('savings.setGoal')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('savings.emoji.🎮')));
    await tester.enterText(find.byKey(const Key('savings.title')), 'Oyun');
    await tester.tap(find.byKey(const Key('savings.cherries.500')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('savings.save')));
    await tester.pumpAndSettle();
    expect(api.calls, ['🎮 Oyun 500']);
    expect(find.text('12 / 500 kiraz'), findsOneWidget);

    await tester.tap(find.byKey(const Key('savings.goal')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('savings.clear')));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'clear');
    expect(find.byKey(const Key('savings.setGoal')), findsOneWidget);
  });

  testWidgets('parents set the weekly allowance and pay', (tester) async {
    _phone(tester);
    final repo = _Repo();
    await tester.pumpWidget(_app(const AllowanceScreen(familyId: 'f1', childId: 'c1', childName: 'Ela'), repo: repo));
    await tester.pumpAndSettle();

    expect(find.text('Ela · Harçlık'), findsOneWidget);
    expect(find.text('10 = 5 ₺'), findsOneWidget);
    expect(find.text('Ela 40 kirazı harçlığa çevirmek istiyor'), findsOneWidget);

    await tester.tap(find.byKey(const Key('allowance.weekly.20')));
    await tester.pumpAndSettle();
    expect(repo.calls.last, 'save 10=5.0 weekly 20 expenses true');

    await tester.tap(find.byKey(const Key('allowance.rate')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('rate.amount')), '2,5');
    await tester.pump();
    await tester.tap(find.byKey(const Key('rate.ok')));
    await tester.pumpAndSettle();
    expect(repo.calls.last, 'save 10=2.5 weekly 20 expenses true');

    await tester.scrollUntilVisible(find.byKey(const Key('allowance.paid.r1')), 200);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('allowance.paid.r1')));
    await tester.pumpAndSettle();
    expect(repo.calls.last, 'decide r1 true');
    await tester.scrollUntilVisible(find.text('Hally para tutmaz ve ödeme yapmaz; sadece ne kadar verdiğinizi takip eder.'), 300);
    expect(find.text('Ödendi'), findsOneWidget);
  });

  testWidgets('Today shows waiting conversions with Ödedim / Şimdi değil', (tester) async {
    final repo = _Repo();
    await tester.pumpWidget(_app(const Scaffold(body: SingleChildScrollView(child: ParentAllowanceCard(familyId: 'f1'))), repo: repo));
    await tester.pumpAndSettle();
    expect(find.text('= 20 ₺'), findsOneWidget);
    await tester.tap(find.byKey(const Key('allowance.later.r1')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['decide r1 false']);
    expect(find.byKey(const Key('allowance.request.r1')), findsNothing);
  });

  test('money, steps and the push route', () {
    expect(formatMoney(20, 'TRY', 'tr'), '20 ₺');
    expect(formatMoney(2.5, 'TRY', 'tr'), '2,50 ₺');
    expect(formatMoney(2.5, 'TRY', 'en'), '₺2.50');
    expect(const ChildSavings(balance: 47).convertible, 40);
    expect(const AllowanceSettings().amountFor(40), 20);
    expect(pushRoute({'kind': 'AllowanceRequest', 'familyId': 'f1', 'targetId': 'c1'}), '/allowance/c1?familyId=f1');
  });
}
