import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hally/core/auth/auth_repository.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/features/notifications/push.dart';
import 'package:hally/features/tips/tips.dart';
import 'package:hally/features/tips/weekly_report.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

const _me = Me(id: 'u1', displayName: 'Ayşe Yılmaz', locale: 'tr', families: [FamilyRef(id: 'f1', name: 'Yılmaz')]);

class _FakeTips implements TipsRepository {
  final dismissed = <(String, bool)>[];
  final limits = <(String, int, DateTime?)>[];

  @override
  Future<List<Tip>> list(String familyId) async => [
        Tip(
          key: 'exam-screen:c1',
          kind: 'ExamScreen',
          emoji: '📝',
          text: 'Ela bu hafta 2 sınava giriyor. Ekran süresini biraz azaltmak ister misin?',
          actionLabel: 'Limiti 60 dk yap',
          action: 'screenLimit',
          childId: 'c1',
          minutes: 60,
          currentMinutes: 120,
          restoreOn: DateTime(2026, 11, 28),
          detail: 'Sınavlar: Perşembe Matematik, Cuma Fen',
        ),
        const Tip(key: 'overdue:1', kind: 'Overdue', emoji: '✅', text: '3 iş gecikti.', actionLabel: 'Görevlere git', action: 'route', route: '/tasks'),
      ];

  @override
  Future<void> dismiss(String familyId, String key, {required bool forever}) async => dismissed.add((key, forever));

  @override
  Future<void> screenLimit(String familyId, String childId, int minutes, DateTime? restoreOn) async => limits.add((childId, minutes, restoreOn));

  @override
  Future<void> bedtimeEarlier(String familyId, String childId, int minutes) async {}

  @override
  Future<TipSettings> settings(String familyId) async =>
      const TipSettings(enabled: true, hidden: 2, reportDay: 'Sunday', reportTime: '19:00', canGetReport: true);

  @override
  Future<TipSettings> saveSettings(String familyId, {required bool enabled, required String reportDay, String? reportTime}) => settings(familyId);

  @override
  Future<TipSettings> restoreHidden(String familyId) => settings(familyId);
}

Widget _app(ProviderContainer c, Widget home) {
  final router = GoRouter(initialLocation: '/', routes: [
    GoRoute(path: '/', builder: (_, __) => home),
    GoRoute(path: '/tasks', builder: (_, __) => const Scaffold(body: Text('TASKS'))),
    GoRoute(path: '/weekly-card', builder: (_, __) => const Scaffold(body: Text('CARD'))),
  ]);
  return UncontrolledProviderScope(
    container: c,
    child: MaterialApp.router(
      theme: buildHallyTheme(Brightness.light),
      locale: const Locale('tr'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
    ),
  );
}

WeeklyReport _report() => WeeklyReport.fromJson({
      'offset': 0,
      'weekStart': '2026-11-23',
      'weekEnd': '2026-11-29',
      'tasksDone': 23,
      'tasksDonePrevious': 18,
      'events': 9,
      'exams': 2,
      'adults': [
        {'userId': 'u1', 'firstName': 'Güler', 'completed': 13},
        {'userId': 'u2', 'firstName': 'Mert', 'completed': 10},
      ],
      'helperCompleted': 0,
      'children': [
        {
          'childId': 'c1',
          'firstName': 'Ela',
          'color': 'sky',
          'exams': [
            {'id': 'x1', 'subject': 'Matematik', 'date': '2026-11-26', 'outcome': 'Good'},
            {'id': 'x2', 'subject': 'Fen', 'date': '2026-11-27', 'outcome': 'Great'},
          ],
          'studyMinutes': 200,
          'screenAvgMinutes': 75,
          'sleepAvgMinutes': null,
          'cherries': 14,
          'activities': 0,
        },
      ],
      'nextWeek': {
        'weekStart': '2026-11-30',
        'exams': [
          {'childId': 'c1', 'childName': 'Ela', 'subject': 'Türkçe', 'date': '2026-11-30'},
        ],
        'events': 7,
        'busiestDay': '2026-12-02',
        'busiestCount': 3,
      },
      'tip': 'Çarşamba çok dolu (3 etkinlik).',
      'quiet': false,
    });

void main() {
  test('the weekly report notification opens the report', () {
    expect(pushRoute({'kind': 'WeeklyReport', 'familyId': 'f1'}), '/weekly-report');
  });

  testWidgets('a tip: the limit sheet applies 60 min until the exams are over, Sonra hides the next one', (tester) async {
    final fake = _FakeTips();
    final c = ProviderContainer(overrides: [tipsRepositoryProvider.overrideWithValue(fake)]);
    addTearDown(c.dispose);
    await tester.pumpWidget(_app(c, const Scaffold(body: Padding(padding: EdgeInsets.all(16), child: TodayTipCard(familyId: 'f1')))));
    await tester.pumpAndSettle();

    expect(find.text('Hally fark etti'), findsOneWidget);
    expect(find.textContaining('Ela bu hafta 2 sınava giriyor'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tip.action.ExamScreen')));
    await tester.pumpAndSettle();
    expect(find.text('Sınavlar: Perşembe Matematik, Cuma Fen'), findsOneWidget);
    expect(find.text('Şu an: 120 dk'), findsOneWidget);
    expect(find.text('Cumartesi limit tekrar 120 dk olur'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tip.screen.apply')));
    await tester.pumpAndSettle();
    expect(fake.limits.single, ('c1', 60, DateTime(2026, 11, 28)));

    // The applied tip is gone; the next one shows and "Sonra" hides it until tomorrow.
    expect(find.textContaining('3 iş gecikti.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tip.later.Overdue')));
    await tester.pumpAndSettle();
    expect(fake.dismissed.single, ('overdue:1', false));
    expect(find.byKey(const Key('today.tip')), findsNothing);
  });

  testWidgets('settings: tips on, hidden ones come back, the weekly report day and time', (tester) async {
    final c = ProviderContainer(overrides: [
      meProvider.overrideWith((ref) async => _me),
      tipsRepositoryProvider.overrideWithValue(_FakeTips()),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(_app(c, const TipsSettingsScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Kapattığın 2 ipucu'), findsOneWidget);
    expect(find.text('Pazar akşamı'), findsOneWidget);
    expect(find.text('19:00'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the weekly report shows the week, who did what, each child and next week', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(overrides: [
      meProvider.overrideWith((ref) async => _me),
      weeklyReportProvider.overrideWith((ref, args) async => _report()),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(_app(c, const WeeklyReportScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Haftanın özeti'), findsOneWidget);
    expect(find.text('23'), findsOneWidget);
    expect(find.text('+5'), findsOneWidget);
    expect(find.text('Kim ne yaptı'), findsOneWidget);
    expect(find.text('📝 2 sınav · İyi, Çok iyi'), findsOneWidget);
    expect(find.text('📚 3 sa 20 dk çalışma'), findsOneWidget);
    expect(find.text('📱 ort. 1 sa 15 dk/gün ekran'), findsOneWidget);
    expect(find.text('🍒 +14'), findsOneWidget);
    expect(find.text('Gelecek hafta'), findsOneWidget);
    expect(find.text('Çarşamba çok dolu (3 etkinlik).'), findsOneWidget);

    await tester.tap(find.byKey(const Key('report.share')));
    await tester.pumpAndSettle();
    expect(find.text('CARD'), findsOneWidget);
  });
}
