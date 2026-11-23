import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/auth/auth_repository.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/features/duties/duties_repository.dart';
import 'package:hally/features/duties/duties_screen.dart';
import 'package:hally/features/messages/chat_realtime.dart';
import 'package:hally/features/notifications/push.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

const _me = Me(id: 'u1', displayName: 'Ayşe', locale: 'tr', families: [FamilyRef(id: 'f1', name: 'Yılmaz')]);
final _monday = DateTime(2026, 11, 23);

class _FakeDuties implements DutiesRepository {
  final calls = <String>[];
  DateTime? doneAt;

  DutyWeek get _week => DutyWeek(
        start: _monday,
        today: _monday,
        adults: const [DutyAdult(userId: 'u1', name: 'Ayşe'), DutyAdult(userId: 'u2', name: 'Mehmet')],
        days: [
          for (var i = 0; i < 7; i++)
            DutyDay(
              date: _monday.add(Duration(days: i)),
              dropOff: i < 5
                  ? DutySlot(kind: 'DropOff', assigned: true, assigneeUserId: 'u1', assigneeName: 'Ayşe', time: const TimeOfDay(hour: 8, minute: 15), doneAt: i == 0 ? doneAt : null, doneByName: i == 0 && doneAt != null ? 'Ayşe' : null)
                  : const DutySlot(kind: 'DropOff'),
              pickUp: i < 5 ? const DutySlot(kind: 'PickUp', assigned: true, assigneeUserId: 'u2', assigneeName: 'Mehmet') : const DutySlot(kind: 'PickUp'),
            ),
        ],
      );

  @override
  Future<DutyWeek> week(String familyId, {DateTime? start}) async => _week;

  @override
  Future<DutyWeek> setRule(String familyId, int weekday, String kind, DutyAssignee assignee) async {
    calls.add('rule $weekday $kind ${assignee.userId ?? assignee.name}');
    return _week;
  }

  @override
  Future<DutyWeek> setDay(String familyId, DateTime date, String kind, DutyAssignee assignee) async {
    calls.add('day ${dutyDate(date)} $kind ${assignee.userId ?? assignee.name ?? 'none'}');
    return _week;
  }

  @override
  Future<DutyWeek> resetDay(String familyId, DateTime date, String kind) async => _week;

  @override
  Future<DutyWeek> done(String familyId, String kind) async {
    calls.add('done $kind');
    doneAt = DateTime(2026, 11, 23, 8, 20);
    return _week;
  }

  @override
  Future<DutyWeek> undone(String familyId, String kind) async {
    calls.add('undone $kind');
    doneAt = null;
    return _week;
  }
}

Widget _app(_FakeDuties repo) => ProviderScope(
      overrides: [
        meProvider.overrideWith((ref) async => _me),
        dutiesRepositoryProvider.overrideWithValue(repo),
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
        home: const DutiesScreen(),
      ),
    );

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  test('the done push opens the school run', () {
    expect(pushRoute({'kind': 'DutyDone'}), '/school-run');
  });

  testWidgets('today shows who does it and the done tap', (tester) async {
    _phone(tester);
    final repo = _FakeDuties();
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();
    expect(find.text('Ayşe · 08:15'), findsWidgets);
    expect(find.byKey(const Key('duties.today.PickUp')), findsOneWidget);

    await tester.tap(find.byKey(const Key('duties.done.DropOff')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['done DropOff']);
    expect(find.text('Ayşe · 08:20'), findsOneWidget);

    await tester.tap(find.byKey(const Key('duties.undo.DropOff')));
    await tester.pumpAndSettle();
    expect(repo.calls.last, 'undone DropOff');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a day changes to someone else, or every week', (tester) async {
    _phone(tester);
    final repo = _FakeDuties();
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('duties.slot.2026-11-26.PickUp')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('duties.who.other')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('duties.name')), 'Babaanne');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('duties.save')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['day 2026-11-26 PickUp Babaanne']);

    await tester.tap(find.byKey(const Key('duties.slot.2026-11-27.DropOff')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('duties.who.u2')));
    await tester.tap(find.byKey(const Key('duties.everyWeek')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('duties.save')));
    await tester.pumpAndSettle();
    expect(repo.calls.last, 'rule 4 DropOff u2');
    await tester.pumpWidget(const SizedBox());
  });
}
