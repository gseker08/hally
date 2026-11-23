import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/auth/auth_repository.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/features/family/family_repository.dart';
import 'package:hally/features/medications/medications_repository.dart';
import 'package:hally/features/medications/medications_screen.dart';
import 'package:hally/features/messages/chat_realtime.dart';
import 'package:hally/features/notifications/push.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

const _me = Me(id: 'u1', displayName: 'Ayşe', locale: 'tr', families: [FamilyRef(id: 'f1', name: 'Yılmaz')]);
const _ela = ChildProfile(id: 'c1', firstName: 'Ela', color: 'sky');

class _FakeMeds implements MedicationsRepository {
  final calls = <String>[];
  final doseList = <Dose>[];
  var meds = <Medication>[];

  @override
  Future<List<Medication>> list(String familyId, {bool includeInactive = false}) async => meds.where((m) => m.active).toList();

  @override
  Future<Medication> create(String familyId, MedicationInput input) async {
    calls.add('create ${input.childId} ${input.name} ${input.dose} ${input.minIntervalMinutes} ${input.maxDosesPerDay} ${input.remindNextDose}');
    final m = Medication(id: 'm${meds.length + 1}', childId: input.childId, name: input.name, dose: input.dose, minIntervalMinutes: input.minIntervalMinutes);
    meds = [...meds, m];
    return m;
  }

  @override
  Future<Medication> update(String familyId, String id, MedicationInput input) async {
    calls.add('update $id active=${input.active}');
    meds = [for (final m in meds) m.id == id ? Medication(id: id, childId: m.childId, name: input.name, minIntervalMinutes: input.minIntervalMinutes, active: input.active) : m];
    return meds.firstWhere((m) => m.id == id);
  }

  @override
  Future<void> delete(String familyId, String id) async => calls.add('delete $id');

  @override
  Future<List<Dose>> doses(String familyId, String id) async => doseList;

  @override
  Future<Medication> give(String familyId, String id, {DateTime? givenAt, String? note, bool force = false}) async {
    calls.add('give $id force=$force');
    final m = meds.firstWhere((m) => m.id == id);
    if (!force && !m.canGiveAt(DateTime.now())) {
      throw DoseWarning(code: 'medication.too_soon', lastDose: m.lastDose!, nextAllowedAt: m.nextAllowedAt);
    }
    return m;
  }

  @override
  Future<void> deleteDose(String familyId, String id, String doseId) async => calls.add('deleteDose $doseId');
}

Widget _app(_FakeMeds repo) => ProviderScope(
      overrides: [
        meProvider.overrideWith((ref) async => _me),
        medicationsRepositoryProvider.overrideWithValue(repo),
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
        home: const MedicationsScreen(),
      ),
    );

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  test('medication pushes open the medication page', () {
    expect(pushRoute({'kind': 'MedicationGiven'}), '/medications');
    expect(pushRoute({'kind': 'MedicationDue', 'targetId': 'm1'}), '/medications');
  });

  test('a dose may be given once the next allowed time has passed', () {
    final now = DateTime(2026, 11, 23, 14);
    expect(const Medication(id: 'm', childId: 'c', name: 'X', minIntervalMinutes: 60).canGiveAt(now), isTrue);
    expect(Medication(id: 'm', childId: 'c', name: 'X', minIntervalMinutes: 60, nextAllowedAt: now.add(const Duration(minutes: 1))).canGiveAt(now), isFalse);
    expect(Medication(id: 'm', childId: 'c', name: 'X', minIntervalMinutes: 60, nextAllowedAt: now).canGiveAt(now), isTrue);
  });

  testWidgets('adding a medication sends the parents\' own interval', (tester) async {
    _phone(tester);
    final repo = _FakeMeds();
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();
    expect(find.text('Kayıtlı ilaç yok'), findsOneWidget);

    await tester.tap(find.byKey(const Key('medication.add')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('medication.save')));
    await tester.tap(find.byKey(const Key('medication.save')));
    await tester.pumpAndSettle();
    expect(find.text('Çocuk, ilaç adı ve doz aralığını seçin.'), findsOneWidget);
    expect(repo.calls, isEmpty);

    await tester.enterText(find.byKey(const Key('medication.name')), 'Ateş şurubu');
    await tester.enterText(find.byKey(const Key('medication.dose')), '5 ml');
    for (final key in ['medication.interval.6', 'medication.max.4']) {
      await tester.ensureVisible(find.byKey(Key(key)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key(key)));
      await tester.pump();
    }
    await tester.ensureVisible(find.byKey(const Key('medication.save')));
    await tester.tap(find.byKey(const Key('medication.save')));
    await tester.pumpAndSettle();

    expect(repo.calls, ['create c1 Ateş şurubu 5 ml 360 4 true'], reason: 'the only child is picked for you');
    expect(find.text('Ateş şurubu · 5 ml'), findsOneWidget);
    expect(find.text('Şimdi verilebilir'), findsOneWidget);
  });

  testWidgets('an early dose asks first, naming who gave the last one', (tester) async {
    _phone(tester);
    final now = DateTime.now();
    final repo = _FakeMeds()
      ..meds = [
        Medication(
          id: 'm1',
          childId: 'c1',
          name: 'Ateş şurubu',
          minIntervalMinutes: 360,
          lastDose: Dose(id: 'd1', givenAt: now.subtract(const Duration(hours: 1)), givenByName: 'Mehmet'),
          dosesLast24h: 1,
          nextAllowedAt: now.add(const Duration(hours: 5)),
        ),
      ];
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();
    expect(find.textContaining('Sonraki doz'), findsOneWidget);
    expect(find.textContaining('Mehmet'), findsOneWidget);

    await tester.tap(find.byKey(const Key('medication.give.m1')));
    await tester.pumpAndSettle();
    expect(find.text('Erken olabilir'), findsOneWidget);

    // Cancel: nothing forced.
    await tester.tap(find.text('İptal').last);
    await tester.pumpAndSettle();
    expect(repo.calls, ['give m1 force=false']);

    await tester.tap(find.byKey(const Key('medication.give.m1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('medication.force')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['give m1 force=false', 'give m1 force=false', 'give m1 force=true']);
  });

  testWidgets('history lets you undo a dose and end the course', (tester) async {
    _phone(tester);
    final repo = _FakeMeds()
      ..meds = [const Medication(id: 'm1', childId: 'c1', name: 'Antibiyotik', minIntervalMinutes: 720)]
      ..doseList.add(Dose(id: 'd9', givenAt: DateTime.now(), givenByName: 'Ayşe', overrodeWarning: true));
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Antibiyotik'));
    await tester.pumpAndSettle();
    expect(find.text('12 sa arayla'), findsOneWidget);
    await tester.tap(find.byKey(const Key('dose.delete.d9')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['deleteDose d9']);

    await tester.tap(find.byKey(const Key('medication.end')));
    await tester.pumpAndSettle();
    expect(repo.calls.last, 'update m1 active=false');
    expect(find.text('Kayıtlı ilaç yok'), findsOneWidget);
  });
}
