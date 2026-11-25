import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/auth/auth_repository.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/features/balance/balance_repository.dart';
import 'package:hally/features/balance/balance_screen.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

const _ayse = Me(id: 'u1', displayName: 'Ayşe', locale: 'tr', families: [FamilyRef(id: 'f1', name: 'Yılmaz')]);
const _mehmet = Me(id: 'u2', displayName: 'Mehmet', locale: 'tr', families: [FamilyRef(id: 'f1', name: 'Yılmaz')]);

class _FakeBalance implements BalanceRepository {
  final calls = <String>[];

  @override
  Future<FamilyBalance> balance(String familyId, {DateTime? from, DateTime? to}) async {
    calls.add(from == null ? 'this' : 'range');
    final empty = from != null;
    return FamilyBalance(
      from: DateTime(2026, 11, 23),
      to: DateTime(2026, 11, 26),
      today: DateTime(2026, 11, 26),
      members: [
        BalanceMember(userId: 'u1', name: 'Ayşe', role: 'Parent', tasks: empty ? 0 : 9, schoolRuns: empty ? 0 : 5, feedings: empty ? 0 : 3),
        BalanceMember(userId: 'u2', name: 'Mehmet', role: 'Parent', tasks: empty ? 0 : 2, schoolRuns: empty ? 0 : 1),
        BalanceMember(userId: 'u3', name: 'Fatma', role: 'Caregiver', feedings: empty ? 0 : 4),
      ],
      suggestion: empty
          ? null
          : BalanceSuggestion(heavyUserId: 'u1', heavyName: 'Ayşe', sharePercent: 71, toUserId: 'u2', toName: 'Mehmet', date: DateTime(2026, 11, 27), kind: 'PickUp'),
    );
  }
}

Widget _app(_FakeBalance repo, Me me) => ProviderScope(
      overrides: [
        meProvider.overrideWith((ref) async => me),
        balanceRepositoryProvider.overrideWithValue(repo),
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
        home: const BalanceScreen(),
      ),
    );

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('shows who did what and offers the busy parent a message', (tester) async {
    _phone(tester);
    final repo = _FakeBalance();
    await tester.pumpWidget(_app(repo, _ayse));
    await tester.pumpAndSettle();

    expect(find.text('Bu hafta kim ne yaptı?'), findsOneWidget);
    expect(find.text('17'), findsOneWidget);
    expect(find.text('Bakıcı'), findsOneWidget);
    expect(find.text('Ayşe bu hafta işlerin %71 kadarını yaptı.'), findsOneWidget);
    expect(find.text('Cuma okuldan alma işini Mehmet alabilir mi?'), findsOneWidget);
    expect(find.byKey(const Key('balance.ask')), findsOneWidget);

    await tester.tap(find.byKey(const Key('balance.lastWeek')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['this', 'range']);
    expect(find.byKey(const Key('balance.suggestion')), findsNothing);
    expect(find.byKey(const Key('balance.empty')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the other parent sees the nudge without the message button', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(_FakeBalance(), _mehmet));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('balance.suggestion')), findsOneWidget);
    expect(find.byKey(const Key('balance.ask')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
