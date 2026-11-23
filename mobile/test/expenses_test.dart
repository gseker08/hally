import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/auth/auth_repository.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/features/expenses/expenses_repository.dart';
import 'package:hally/features/expenses/expenses_screen.dart';
import 'package:hally/features/messages/chat_realtime.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

const _me = Me(id: 'u2', displayName: 'Mehmet', locale: 'tr', families: [FamilyRef(id: 'f1', name: 'Yılmaz')]);

class _FakeExpenses implements ExpensesRepository {
  final calls = <String>[];
  final expenses = <Expense>[
    Expense(id: 'e1', title: 'Okul gezisi', amount: 699.5, category: 'School', date: DateTime.now(), paidByUserId: 'u1', paidByName: 'Ayşe', myShare: 349.75),
  ];
  double settled = 0;

  ExpenseMonth _month(String? month) {
    final total = expenses.fold<double>(0, (a, e) => a + e.amount);
    final ayse = expenses.where((e) => e.paidByUserId == 'u1').fold<double>(0, (a, e) => a + e.amount) - total / 2 - settled;
    return ExpenseMonth(
      month: month ?? '',
      total: total,
      byCategory: {for (final e in expenses) e.category: e.amount},
      expenses: List.of(expenses),
      settlements: [if (settled > 0) Settlement(id: 's1', fromUserId: 'u2', fromName: 'Mehmet', toUserId: 'u1', toName: 'Ayşe', amount: settled, date: DateTime.now())],
      balances: [ExpenseBalance(userId: 'u1', name: 'Ayşe', net: ayse), ExpenseBalance(userId: 'u2', name: 'Mehmet', net: -ayse)],
      suggestion: ayse.abs() < 0.005
          ? null
          : ayse > 0
              ? SettleSuggestion(fromUserId: 'u2', fromName: 'Mehmet', toUserId: 'u1', toName: 'Ayşe', amount: ayse)
              : SettleSuggestion(fromUserId: 'u1', fromName: 'Ayşe', toUserId: 'u2', toName: 'Mehmet', amount: -ayse),
    );
  }

  @override
  Future<ExpenseMonth> month(String familyId, String? month) async => _month(month);

  @override
  Future<ExpenseMonth> add(String familyId,
      {required String title, required double amount, required String category, DateTime? date, String? paidByUserId, String? childId, String? note}) async {
    calls.add('add $title $amount $category $paidByUserId');
    expenses.add(Expense(id: 'e${expenses.length + 1}', title: title, amount: amount, category: category, date: date ?? DateTime.now(), paidByUserId: paidByUserId!));
    return _month(null);
  }

  @override
  Future<ExpenseMonth> delete(String familyId, String expenseId) async {
    calls.add('delete $expenseId');
    expenses.removeWhere((e) => e.id == expenseId);
    return _month(null);
  }

  @override
  Future<ExpenseMonth> settle(String familyId, {required String toUserId, required double amount}) async {
    calls.add('settle $toUserId $amount');
    settled += amount;
    return _month(null);
  }

  @override
  Future<ExpenseMonth> deleteSettlement(String familyId, String settlementId) async => _month(null);
}

Widget _app(_FakeExpenses repo) => ProviderScope(
      overrides: [
        meProvider.overrideWith((ref) async => _me),
        expensesRepositoryProvider.overrideWithValue(repo),
        chatRealtimeProvider.overrideWithValue(NoChatRealtime()),
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
        home: const ExpensesScreen(),
      ),
    );

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  test('parses Turkish and plain amounts', () {
    expect(parseExpenseAmount('12,5'), 12.5);
    expect(parseExpenseAmount('1.250,00'), 1250);
    expect(parseExpenseAmount('12.345'), 12.35);
    expect(parseExpenseAmount('0'), isNull);
    expect(parseExpenseAmount('abc'), isNull);
  });

  testWidgets('shows who owes whom and records a payment', (tester) async {
    _phone(tester);
    final repo = _FakeExpenses();
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('expenses.suggestion')), findsOneWidget);
    expect(find.textContaining('Mehmet, Ayşe kişisine'), findsOneWidget);
    expect(find.textContaining('349,75'), findsWidgets);

    await tester.tap(find.byKey(const Key('expenses.settle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('expenses.settleSave')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['settle u1 349.75']);
    expect(find.byKey(const Key('expenses.square')), findsOneWidget);
    expect(find.text('Ödemeler'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('adds an expense paid by me', (tester) async {
    _phone(tester);
    final repo = _FakeExpenses();
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('expenses.add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('expenses.title')), 'Mont');
    await tester.enterText(find.byKey(const Key('expenses.amount')), 'abc');
    await tester.tap(find.byKey(const Key('expenses.save')));
    await tester.pumpAndSettle();
    expect(repo.calls, isEmpty);
    await tester.enterText(find.byKey(const Key('expenses.amount')), '1.200,00');
    await tester.tap(find.byKey(const Key('expenses.cat.Clothes')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('expenses.save')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['add Mont 1200.0 Clothes u2']);
    expect(find.text('Mont'), findsOneWidget);
    // Mehmet paid more now, so Ayşe owes him: no "I paid" button for Mehmet.
    expect(find.byKey(const Key('expenses.settle')), findsNothing);
    expect(find.textContaining('Ayşe, Mehmet kişisine'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
