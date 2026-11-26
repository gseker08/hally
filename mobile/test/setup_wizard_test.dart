import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/features/assistant/briefing.dart';
import 'package:hally/features/family/family_repository.dart';
import 'package:hally/features/setup/focus.dart';
import 'package:hally/features/setup/setup_wizard.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

class _Family extends Fake implements FamilyRepository {
  final added = <(String, int?)>[];

  @override
  Future<ChildProfile> addChild(String familyId, {required String firstName, int? birthYear, String? color}) async {
    added.add((firstName, birthYear));
    return ChildProfile(id: 'c${added.length}', firstName: firstName, birthYear: birthYear, color: color ?? 'sky');
  }
}

class _Focus implements FocusRepository {
  List<FocusArea>? saved;

  @override
  Future<FocusSettings> get(String familyId) async => FocusSettings(areas: saved ?? const [], setupDone: saved != null);

  @override
  Future<FocusSettings> set(String familyId, List<FocusArea> areas) async {
    saved = areas;
    return FocusSettings(areas: areas, setupDone: true);
  }
}

class _Briefing extends Fake implements BriefingRepository {
  String? value;

  @override
  Future<String?> time(String familyId) async => value;

  @override
  Future<String?> setTime(String familyId, String? time) async => value = time;
}

void main() {
  test('suggestions follow the children\'s ages and never pass four', () {
    expect(suggestFocus([8, 2]), [FocusArea.school, FocusArea.tasks, FocusArea.baby]);
    expect(suggestFocus([12, 4, 1]), [FocusArea.school, FocusArea.tasks, FocusArea.baby, FocusArea.screen]);
    expect(suggestFocus([]), [FocusArea.tasks, FocusArea.shopping, FocusArea.teamwork]);
    expect(const FocusSettings(areas: [], setupDone: true).shows(FocusArea.cherries), isTrue);
    expect(const FocusSettings(areas: [FocusArea.school], setupDone: true).shows(FocusArea.cherries), isFalse);
  });

  testWidgets('a new family: children, pre-selected areas, morning summary, then the partner invite', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final family = _Family();
    final focus = _Focus();
    final briefing = _Briefing();
    final year = DateTime.now().year;
    final c = ProviderContainer(overrides: [
      familyRepositoryProvider.overrideWithValue(family),
      familyProvider.overrideWith((ref, id) async =>
          FamilyDetails(id: id, name: 'Yılmaz', timeZoneId: 'Europe/Istanbul', members: const [], children: const [])),
      focusRepositoryProvider.overrideWithValue(focus),
      briefingRepositoryProvider.overrideWithValue(briefing),
    ]);
    addTearDown(c.dispose);
    final router = GoRouter(initialLocation: '/setup', routes: [
      GoRoute(path: '/setup', builder: (_, __) => const SetupWizardScreen(familyId: 'f1', next: '/invite')),
      GoRoute(path: '/invite', builder: (_, __) => const Scaffold(body: Text('INVITE'))),
    ]);
    await tester.pumpWidget(UncontrolledProviderScope(
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
    ));
    await tester.pumpAndSettle();

    expect(find.text('Çocuklarını tanıyalım'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('setup.kidName.0')), 'Ela');
    await tester.ensureVisible(find.byKey(Key('setup.kidYear.0.${year - 8}')));
    await tester.tap(find.byKey(Key('setup.kidYear.0.${year - 8}')));
    await tester.pump();
    expect(find.text('${year - 8} · 8 yaş'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('setup.addKid')));
    await tester.tap(find.byKey(const Key('setup.addKid')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('setup.kidName.1')), 'Deniz');
    await tester.ensureVisible(find.byKey(Key('setup.kidYear.1.${year - 2}')));
    await tester.tap(find.byKey(Key('setup.kidYear.1.${year - 2}')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('setup.next')));
    await tester.pumpAndSettle();
    expect(family.added, [('Ela', year - 8), ('Deniz', year - 2)]);

    expect(find.text('Hally en çok neyde yardım etsin?'), findsOneWidget);
    expect(find.textContaining('Ela 8 yaşında, Deniz 2 yaşında'), findsOneWidget);
    expect(find.text('Devam · 3 seçili'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('setup.area.health')));
    await tester.tap(find.byKey(const Key('setup.area.health')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('setup.area.shopping')));
    await tester.tap(find.byKey(const Key('setup.area.shopping'))); // a fifth is refused
    await tester.pump();
    expect(find.text('Devam · 4 seçili'), findsOneWidget);
    expect(find.text('En fazla 4 alan seçebilirsin. Diğerleri Aile sekmesinde duruyor.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('setup.next')));
    await tester.pumpAndSettle();

    expect(find.text('Bugün ekranın hazır'), findsOneWidget);
    expect(find.text('Ödev, okuma'), findsWidgets);
    await tester.tap(find.byKey(const Key('setup.next')));
    await tester.pumpAndSettle();

    expect(focus.saved, [FocusArea.school, FocusArea.tasks, FocusArea.baby, FocusArea.health]);
    expect(briefing.value, '07:30');
    expect(find.text('INVITE'), findsOneWidget);
  });
}
