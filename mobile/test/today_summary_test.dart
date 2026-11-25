import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hally/core/auth/auth_repository.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/features/family/family_repository.dart';
import 'package:hally/features/home/family_today.dart';
import 'package:hally/features/kids/kids_screen.dart' show kidsSelectedProvider;
import 'package:hally/features/planning/planning_repository.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

const _me = Me(id: 'u1', displayName: 'Ayşe Yılmaz', locale: 'tr', families: [FamilyRef(id: 'f1', name: 'Yılmaz')]);

const _family = FamilyDetails(
  id: 'f1',
  name: 'Yılmaz',
  timeZoneId: 'Europe/Istanbul',
  members: [
    FamilyMember(userId: 'u1', displayName: 'Ayşe Yılmaz', role: 'Owner'),
    FamilyMember(userId: 'u2', displayName: 'Mert Yılmaz', role: 'Parent'),
  ],
  children: [
    ChildProfile(id: 'c1', firstName: 'Ela', color: 'sky'),
    ChildProfile(id: 'c2', firstName: 'Can', color: 'mint'),
  ],
);

final _today = TodayData(
  overdue: const [TaskItem(id: 't1', title: 'Beslenme çantası', allDay: true, state: 'Open', childIds: ['c1'])],
  dueToday: const [TaskItem(id: 't2', title: 'Fatura', allDay: true, state: 'Open', assigneeUserId: 'u2')],
  events: [EventItem(id: 'e1', title: 'Yüzme', startsAt: DateTime(2026, 11, 25, 17), allDay: false, childIds: const ['c1', 'c2'])],
  waiting: const [],
);

Widget _app(ProviderContainer c) {
  final router = GoRouter(initialLocation: '/today', routes: [
    GoRoute(path: '/today', builder: (_, __) => Scaffold(body: ListView(children: [FamilyTodayCard(familyId: 'f1', data: _today)]))),
    GoRoute(path: '/kids', builder: (_, __) => const Scaffold(body: Text('KIDS'))),
    GoRoute(path: '/family', builder: (_, __) => const Scaffold(body: Text('FAMILY'))),
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

ProviderContainer _container() => ProviderContainer(overrides: [
      meProvider.overrideWith((ref) async => _me),
      familyProvider.overrideWith((ref, id) async => _family),
    ]);

void main() {
  testWidgets('family today: everyone with their counts, a child opens their page on the Kids tab', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final c = _container();
    addTearDown(c.dispose);
    await tester.pumpWidget(_app(c));
    await tester.pumpAndSettle();

    expect(find.text('Ailem bugün'), findsOneWidget);
    expect(find.text('1 görev · 1 etkinlik'), findsOneWidget); // Ela
    expect(find.text('1 etkinlik'), findsOneWidget); // Can

    await tester.tap(find.byKey(const Key('today.family.child.c1')));
    await tester.pumpAndSettle();
    expect(find.text('KIDS'), findsOneWidget);
    expect(c.read(kidsSelectedProvider), 'c1');
  });

  testWidgets('family today: "Aile" and an adult open the Family tab', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final c = _container();
    addTearDown(c.dispose);
    await tester.pumpWidget(_app(c));
    await tester.pumpAndSettle();

    await tester.dragUntilVisible(find.byKey(const Key('today.family.member.u2')), find.byType(ListView).last, const Offset(-200, 0));
    expect(find.text('Bugün boş'), findsOneWidget); // Ayşe
    expect(find.text('1 görev'), findsOneWidget); // Mert

    await tester.tap(find.byKey(const Key('today.family.all')));
    await tester.pumpAndSettle();
    expect(find.text('FAMILY'), findsOneWidget);
  });
}
