import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/auth/auth_repository.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/features/family/family_repository.dart';
import 'package:hally/features/messages/chat_realtime.dart';
import 'package:hally/features/sleep/sleep_repository.dart';
import 'package:hally/features/sleep/sleep_screen.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

const _me = Me(id: 'u1', displayName: 'Ayşe', locale: 'tr', families: [FamilyRef(id: 'f1', name: 'Yılmaz')]);
const _can = ChildProfile(id: 'c1', firstName: 'Can', color: 'mint');

class _FakeSleep implements SleepRepository {
  final calls = <String>[];
  SleepEntry? open;
  SleepEntry? last;
  final entries = <SleepEntry>[];

  ChildSleepStatus get _status => ChildSleepStatus(childId: 'c1', asleep: open, lastSleep: last);

  @override
  Future<List<ChildSleepStatus>> status(String familyId) async => [_status];

  @override
  Future<SleepHistory> history(String familyId, String childId) async => SleepHistory(
        days: [for (var i = 0; i < 7; i++) SleepDay(date: DateTime(2026, 11, 17 + i), nightMinutes: i == 6 ? 0 : 600, napMinutes: 90, naps: 1)],
        entries: entries,
        averageNightMinutes: 600,
        averageNapMinutes: 90,
      );

  @override
  Future<ChildSleepStatus> asleep(String familyId, String childId, {DateTime? at}) async {
    calls.add('asleep');
    open = SleepEntry(id: 's1', childId: 'c1', kind: 'Nap', startedAt: DateTime.now().subtract(const Duration(minutes: 5)));
    return _status;
  }

  @override
  Future<ChildSleepStatus> awake(String familyId, String childId, {DateTime? at}) async {
    calls.add('awake');
    last = SleepEntry(id: 's1', childId: 'c1', kind: 'Nap', startedAt: open!.startedAt, endedAt: DateTime.now(), minutes: 5);
    open = null;
    return _status;
  }

  @override
  Future<void> add(String familyId, String childId, {required DateTime startedAt, required DateTime endedAt, String? kind}) async =>
      calls.add('add ${endedAt.difference(startedAt).inMinutes}');

  @override
  Future<void> delete(String familyId, String childId, String entryId) async {
    calls.add('delete $entryId');
    entries.removeWhere((e) => e.id == entryId);
  }
}

Widget _app(_FakeSleep repo) => ProviderScope(
      overrides: [
        meProvider.overrideWith((ref) async => _me),
        sleepRepositoryProvider.overrideWithValue(repo),
        chatRealtimeProvider.overrideWithValue(NoChatRealtime()),
        familyProvider.overrideWith((ref, id) async => const FamilyDetails(id: 'f1', name: 'Yılmaz', timeZoneId: 'Europe/Istanbul', members: [], children: [_can])),
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
        home: const SleepScreen(),
      ),
    );

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  test('sleep durations read naturally', () {
    expect(formatSleepMinutes(45, lang: 'tr'), '45 dk');
    expect(formatSleepMinutes(605, lang: 'en'), '10 h 05 min');
  });

  testWidgets('asleep and awake with one tap', (tester) async {
    _phone(tester);
    final repo = _FakeSleep();
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();
    expect(find.text('Henüz uyku kaydı yok'), findsOneWidget);

    await tester.tap(find.byKey(const Key('sleep.toggle.c1')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['asleep']);
    expect(find.textContaining('Uyuyor · 5 dk'), findsOneWidget);

    await tester.tap(find.byKey(const Key('sleep.toggle.c1')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['asleep', 'awake']);
    expect(find.textContaining('Uyanık · 0 dk'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the week shows averages, deletes and adds an overnight sleep', (tester) async {
    _phone(tester);
    final now = DateTime.now();
    final repo = _FakeSleep()..entries.add(SleepEntry(id: 'e1', childId: 'c1', kind: 'Night', startedAt: now.subtract(const Duration(hours: 10)), endedAt: now, minutes: 600));
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sleep.child.c1')));
    await tester.pumpAndSettle();

    expect(find.text('Ortalama gece 10 sa 00 dk · gündüz 1 sa 30 dk'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sleep.delete.e1')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['delete e1']);

    await tester.tap(find.byKey(const Key('sleep.add')));
    await tester.pumpAndSettle();
    // Defaults 13:00 – 14:30; yesterday so the time is surely past.
    await tester.tap(find.byKey(const Key('sleep.yesterday')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sleep.save')));
    await tester.pumpAndSettle();
    expect(repo.calls.last, 'add 90');
    await tester.pumpWidget(const SizedBox());
  });
}
