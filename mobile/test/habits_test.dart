import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/auth/auth_repository.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/features/family/family_repository.dart';
import 'package:hally/features/habits/habits_repository.dart';
import 'package:hally/features/habits/habits_screen.dart';
import 'package:hally/features/messages/chat_realtime.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

const _me = Me(id: 'u1', displayName: 'Ayşe', locale: 'tr', families: [FamilyRef(id: 'f1', name: 'Yılmaz')]);
const _ela = ChildProfile(id: 'c1', firstName: 'Ela', color: 'mint');
const _can = ChildProfile(id: 'c2', firstName: 'Can', color: 'sky');
final _today = DateTime(2026, 11, 23);

class _FakeHabits implements HabitsRepository {
  final calls = <String>[];
  var done = <String>{'2026-11-22'};

  String _d(DateTime d) => '${d.year}-${d.month}-${d.day}'.replaceAllMapped(RegExp(r'-(\d)(?=-|$)'), (m) => '-0${m[1]}');

  HabitsBoard get _board {
    final last = [for (var i = 6; i >= 0; i--) done.contains(_d(_today.subtract(Duration(days: i))))];
    var streak = 0;
    for (var i = 6; i >= 0; i--) {
      if (last[i]) {
        streak++;
      } else if (i != 6) {
        break;
      }
    }
    return HabitsBoard(today: _today, habits: [
      Habit(id: 'h1', childId: 'c1', title: 'Diş fırçalama', doneToday: last.last, streak: streak, best: 5, lastSeven: last),
    ]);
  }

  @override
  Future<HabitsBoard> list(String familyId) async => _board;

  @override
  Future<HabitsBoard> add(String familyId, {required String childId, required String title, int days = everyDay}) async {
    calls.add('add $childId $title $days');
    return _board;
  }

  @override
  Future<HabitsBoard> delete(String familyId, String habitId) async => _board;

  @override
  Future<HabitsBoard> check(String familyId, String habitId, DateTime day) async {
    calls.add('check ${_d(day)}');
    done.add(_d(day));
    return _board;
  }

  @override
  Future<HabitsBoard> uncheck(String familyId, String habitId, DateTime day) async {
    calls.add('uncheck ${_d(day)}');
    done.remove(_d(day));
    return _board;
  }
}

Widget _app(_FakeHabits repo) => ProviderScope(
      overrides: [
        meProvider.overrideWith((ref) async => _me),
        habitsRepositoryProvider.overrideWithValue(repo),
        chatRealtimeProvider.overrideWithValue(NoChatRealtime()),
        familyProvider.overrideWith((ref, id) async => const FamilyDetails(id: 'f1', name: 'Yılmaz', timeZoneId: 'Europe/Istanbul', members: [], children: [_ela, _can])),
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
        home: const HabitsScreen(),
      ),
    );

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('tapping today extends the streak and a day dot fixes the past', (tester) async {
    _phone(tester);
    final repo = _FakeHabits();
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();
    expect(find.text('Seri: 1 gün · en iyi 5'), findsOneWidget);

    await tester.tap(find.byKey(const Key('habits.today.h1')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['check 2026-11-23']);
    expect(find.text('Seri: 2 gün · en iyi 5'), findsOneWidget);

    // Two days ago (dot 4 of 0..6).
    await tester.tap(find.byKey(const Key('habits.day.h1.4')));
    await tester.pumpAndSettle();
    expect(repo.calls.last, 'check 2026-11-21');
    expect(find.text('Seri: 3 gün · en iyi 5'), findsOneWidget);

    await tester.tap(find.byKey(const Key('habits.today.h1')));
    await tester.pumpAndSettle();
    expect(repo.calls.last, 'uncheck 2026-11-23');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('adds a weekday habit for the chosen child', (tester) async {
    _phone(tester);
    final repo = _FakeHabits();
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('habits.add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('habits.child.c2')));
    await tester.enterText(find.byKey(const Key('habits.title')), 'Yatağını topla');
    await tester.tap(find.byKey(const Key('habits.weekday.5')));
    await tester.tap(find.byKey(const Key('habits.weekday.6')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('habits.save')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['add c2 Yatağını topla 31']);
    await tester.pumpWidget(const SizedBox());
  });
}
