import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/auth/auth_repository.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/features/family/family_repository.dart';
import 'package:hally/features/handoff/handoff_cards.dart';
import 'package:hally/features/handoff/handoff_repository.dart';
import 'package:hally/features/handoff/handoff_screen.dart';
import 'package:hally/features/notifications/push.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

const _summary = HandoffSummary(feeds: 3, solids: 2, foods: ['Çorba', 'Muz'], bottleMl: 150, sleepMinutes: 85, sleeps: ['13:10–14:35'], doses: ['Şurup 5 ml · 12:00'], screenMinutes: 40);

HandoffReport _report({List<HandoffIncident> incidents = const [HandoffIncident.fall], DateTime? thankedAt}) => HandoffReport(
      id: 'r1',
      childId: 'c1',
      childName: 'Ela',
      byUserId: 'u3',
      byName: 'Fatma Kaya',
      day: DateTime(2026, 11, 25),
      summary: _summary,
      incidents: incidents,
      note: 'Parkta dizini sıyırdı.',
      sentAt: DateTime(2026, 11, 25, 18, 6),
      thankedAt: thankedAt,
    );

class _FakeHandoff implements HandoffRepository {
  final calls = <String>[];
  HandoffReport? sent;

  @override
  Future<HandoffDraft> draft(String familyId, String childId) async => HandoffDraft(day: DateTime(2026, 11, 25), summary: _summary, sent: sent);

  @override
  Future<HandoffReport> send(String familyId, String childId, {required Set<HandoffIncident> incidents, String? note}) async {
    calls.add('send $childId ${incidents.map((i) => i.name).join(',')} $note');
    return sent = _report(incidents: incidents.toList());
  }

  @override
  Future<HandoffReport> addPhoto(String familyId, String reportId, List<int> bytes, String fileName, String contentType) async => _report();

  @override
  Future<Uint8List> photo(String familyId, String reportId) async => Uint8List(0);

  @override
  Future<List<HandoffReport>> list(String familyId, {String? childId, DateTime? day}) async => [if (!calls.contains('thanks r1')) _report()];

  @override
  Future<HandoffReport> thanks(String familyId, String reportId) async {
    calls.add('thanks $reportId');
    return _report(thankedAt: DateTime.now());
  }
}

const _family = FamilyDetails(
  id: 'f1',
  name: 'Yılmaz',
  timeZoneId: 'Europe/Istanbul',
  members: [
    FamilyMember(userId: 'u1', displayName: 'Ayşe', role: 'Owner'),
    FamilyMember(userId: 'u3', displayName: 'Fatma Kaya', role: 'Caregiver'),
  ],
  children: [ChildProfile(id: 'c1', firstName: 'Ela')],
);

Widget _app(_FakeHandoff repo, Widget home, {String role = 'Owner'}) => ProviderScope(
      overrides: [
        handoffRepositoryProvider.overrideWithValue(repo),
        familyProvider.overrideWith((ref, id) async => _family),
        meProvider.overrideWith((ref) async => Me(id: 'u1', displayName: 'Ayşe', locale: 'tr', families: [FamilyRef(id: 'f1', name: 'Yılmaz', role: role)])),
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
        home: Scaffold(body: home),
      ),
    );

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  test('the report push opens the reports', () {
    expect(pushRoute({'kind': 'HandoffReport'}), '/handoffs');
  });

  testWidgets('the caregiver checks the filled-in day, ticks an incident and sends', (tester) async {
    _phone(tester);
    final repo = _FakeHandoff();
    await tester.pumpWidget(_app(repo, const HandoffScreen(childId: 'c1'), role: 'Caregiver'));
    await tester.pumpAndSettle();

    expect(find.text('2 öğün · Çorba, Muz · Biberon 150 ml'), findsOneWidget);
    expect(find.text('13:10–14:35 (1 sa 25 dk)'), findsOneWidget);
    expect(find.text('Şurup 5 ml · 12:00'), findsOneWidget);

    await tester.tap(find.byKey(const Key('handoff.incident.fall')));
    await tester.scrollUntilVisible(find.byKey(const Key('handoff.note')), 200);
    await tester.enterText(find.byKey(const Key('handoff.note')), 'Parkta dizini sıyırdı.');
    await tester.tap(find.byKey(const Key('handoff.send')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['send c1 fall Parkta dizini sıyırdı.']);
    expect(find.text('Rapor gönderildi'), findsOneWidget);
    expect(find.text('Raporu güncelle'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('parents see the report on Today and say thanks', (tester) async {
    _phone(tester);
    final repo = _FakeHandoff();
    await tester.pumpWidget(_app(repo, const ParentHandoffCards(familyId: 'f1')));
    await tester.pumpAndSettle();

    expect(find.text('Fatma günü bitirdi'), findsOneWidget);
    expect(find.text('2 öğün'), findsOneWidget);
    expect(find.text('1 doz'), findsOneWidget);
    expect(find.text('Küçük düşme'), findsOneWidget);
    expect(find.byKey(const Key('handoff.incidentBox')), findsOneWidget);

    await tester.tap(find.byKey(const Key('handoff.thanks.r1')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['thanks r1']);
    expect(find.byKey(const Key('handoff.report.r1')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a caregiver sees the end-the-day card for their child', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(_FakeHandoff(), const CaregiverHandoffCard(familyId: 'f1'), role: 'Caregiver'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('handoff.open.c1')), findsOneWidget);
    expect(find.text('Ela için akşam raporunu tek dokunuşla gönder.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
