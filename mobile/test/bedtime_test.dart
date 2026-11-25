import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/features/bedtime/bedtime.dart';
import 'package:hally/features/bedtime/bedtime_screens.dart';
import 'package:hally/features/child_mode/child_mode_repository.dart';
import 'package:hally/features/child_mode/kid_screens.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

const _steps = [
  BedtimeStep(title: 'Pijamalarını giy', emoji: '👕'),
  BedtimeStep(title: 'Dişlerini fırçala', emoji: '🪥'),
  BedtimeStep(title: 'Yatağına gir', emoji: '🛏️'),
];

ChildHome _home({ChildBedtime? bedtime, bool nightLocked = false}) => ChildHome(
      childId: 'c1',
      firstName: 'Ela',
      color: 'sky',
      familyName: 'Yılmaz',
      balance: 10,
      today: const [],
      todayMood: 'Good',
      screen: ChildScreen(locked: nightLocked, bedtime: nightLocked),
      bedtime: bedtime,
    );

class _KidApi implements ChildApi {
  _KidApi(this.current);

  ChildHome current;
  final calls = <String>[];

  @override
  Future<ChildHome> home() async => current;

  @override
  Future<ChildBedtime> bedtimeDone(int index) async {
    calls.add('step $index');
    final b = current.bedtime!;
    final done = index + 1;
    final next =
        ChildBedtime(time: b.time, steps: b.steps, open: true, done: done, cherries: b.cherries, finishedAt: done == b.steps.length ? DateTime.now() : null);
    current = _home(bedtime: next, nightLocked: next.finished && b.lockUntilMorning);
    return next;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Speaker implements StorySpeaker {
  final said = <String>[];
  void Function()? done;

  @override
  Future<void> speak(String text, {required String language, required void Function() onDone}) async {
    said.add(language);
    done = onDone;
  }

  @override
  Future<void> stop() async => said.add('stop');
}

class _Repo implements BedtimeRepository {
  BedtimeRoutine? saved;

  @override
  Future<BedtimeState> load(String familyId, String childId) async => const BedtimeState(tonightDone: 2, tonightTotal: 5);

  @override
  Future<BedtimeState> save(String familyId, String childId, BedtimeRoutine routine) async {
    saved = routine;
    return BedtimeState(routine: routine);
  }
}

Widget _app(Widget home, {ChildApi? kid, StorySpeaker? speaker, BedtimeRepository? repo}) => ProviderScope(
      overrides: [
        if (kid != null) childApiProvider.overrideWithValue(kid),
        if (speaker != null) storySpeakerProvider.overrideWithValue(speaker),
        if (repo != null) bedtimeRepositoryProvider.overrideWithValue(repo),
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
        home: home,
      ),
    );

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('at bedtime the steps open, go in order, and end on the locked night page with a story', (tester) async {
    _phone(tester);
    final api = _KidApi(_home(bedtime: const ChildBedtime(time: '20:30', steps: _steps, open: true, cherries: 3)));
    final speaker = _Speaker();
    await tester.pumpWidget(_app(const KidShell(), kid: api, speaker: speaker));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('bed.steps')), findsOneWidget);
    expect(find.text('20:30 · Uyku vakti'), findsOneWidget);

    // A later step cannot be ticked first.
    await tester.tap(find.text('Yatağına gir'));
    await tester.pumpAndSettle();
    expect(api.calls, isEmpty);

    await tester.tap(find.text('Pijamalarını giy'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dişlerini fırçala'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yatağına gir'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(api.calls, ['step 0', 'step 1', 'step 2']);

    expect(find.byKey(const Key('bed.night')), findsOneWidget);
    expect(find.text('İyi geceler Ela'), findsOneWidget);
    expect(find.text('Rutin bitti · +3 kiraz 🍒'), findsOneWidget);
    expect(find.textContaining("Sabah 07:00'ye kadar"), findsOneWidget);
    expect(find.byKey(const Key('bed.close')), findsNothing, reason: 'locked for the night');

    await tester.tap(find.byKey(const Key('bed.play')));
    await tester.pump();
    expect(speaker.said, ['tr']);
    expect(find.text('Durdur'), findsOneWidget);
    speaker.done!();
    await tester.pump();
    expect(tester.widget<AnimatedOpacity>(find.byKey(const Key('bed.dim'))).opacity, greaterThan(0));
  });

  testWidgets('"Sonra" goes home and the card brings the steps back', (tester) async {
    _phone(tester);
    final api = _KidApi(_home(bedtime: const ChildBedtime(time: '20:30', steps: _steps, open: true, done: 1, cherries: 3)));
    await tester.pumpWidget(_app(const KidShell(), kid: api));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('bed.later')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bed.card')), findsOneWidget);
    expect(find.text('1/3 adım · Devam et'), findsOneWidget);
    await tester.tap(find.byKey(const Key('bed.card')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bed.steps')), findsOneWidget);
  });

  testWidgets('without the night lock the good-night page can be closed', (tester) async {
    _phone(tester);
    final api = _KidApi(
        _home(bedtime: ChildBedtime(time: '20:30', steps: _steps, open: true, done: 3, cherries: 0, lockUntilMorning: false, finishedAt: DateTime.now())));
    await tester.pumpWidget(_app(const KidShell(), kid: api));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Rutin bitti 🌙'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('bed.close')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('bed.close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bed.night')), findsNothing);
    expect(find.text('Merhaba Ela!'), findsOneWidget);
  });

  testWidgets('a parent starts from the default steps, edits them and saves', (tester) async {
    _phone(tester);
    final repo = _Repo();
    await tester.pumpWidget(_app(const BedtimeSettingsScreen(familyId: 'f1', childId: 'c1'), repo: repo));
    await tester.pumpAndSettle();

    expect(find.text('Bu akşam: 2/5 adım'), findsOneWidget);
    expect(find.text('Pijamalarını giy'), findsOneWidget);
    expect(find.text('20:30'), findsOneWidget);
    await tester.tap(find.byKey(const Key('bed.remove.2')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('bed.add')), 200);
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bed.add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('bed.step.title')), 'Kitap oku');
    await tester.tap(find.byKey(const Key('bed.step.save')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('bed.cherries.5')), 200);
    await tester.tap(find.byKey(const Key('bed.cherries.5')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('bed.save')));
    await tester.pumpAndSettle();

    final r = repo.saved!;
    expect(r.steps.map((s) => s.title), ['Pijamalarını giy', 'Dişlerini fırçala', 'Su iç, tuvalete git', 'Yatağına gir', 'Kitap oku']);
    expect(r.cherries, 5);
    expect(r.lockUntilMorning, isTrue);
    expect(r.time, '20:30');
  });

  test('the story stays the same all evening and changes the next day', () {
    final a = storyFor(DateTime(2026, 11, 25, 9), 'tr');
    expect(storyFor(DateTime(2026, 11, 25, 22), 'tr').title, a.title);
    expect(storyFor(DateTime(2026, 11, 26, 9), 'tr').title, isNot(a.title));
  });
}
