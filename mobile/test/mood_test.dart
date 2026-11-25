import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/auth/auth_repository.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/features/child_mode/child_mode_repository.dart';
import 'package:hally/features/family/family_repository.dart';
import 'package:hally/features/mood/mood.dart';
import 'package:hally/features/mood/mood_widgets.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

class _KidApi implements ChildApi {
  final calls = <String>[];

  @override
  Future<int> answerMood(String mood, List<String> reasons) async {
    calls.add('$mood ${reasons.join(',')}');
    return 1;
  }

  @override
  Future<ChildHome> home() async => const ChildHome(childId: 'c1', firstName: 'Ela', color: 'cherry', familyName: 'Yılmaz', todayMood: 'Sad');

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Moods implements MoodRepository {
  @override
  Future<MoodWeek> moods(String familyId, String childId, {required DateTime from, required DateTime to}) async {
    final today = DateTime(to.year, to.month, to.day);
    return MoodWeek(
      today: today,
      days: [
        for (var i = 6; i >= 0; i--)
          MoodDay(date: today.subtract(Duration(days: i)), mood: switch (i) { 6 => 'Great', 5 || 4 => 'Good', 3 => 'Sad', 2 => 'Tired', _ => null }, reasons: i == 3 ? ['School'] : const []),
      ],
      mostCommon: 'Good',
      mostCommonDays: 2,
      topReason: 'School',
      nudge: MoodNudge(date: DateTime(2026, 11, 26), mood: 'Sad', reason: 'School'),
    );
  }
}

const _family = FamilyDetails(id: 'f1', name: 'Yılmaz', timeZoneId: 'Europe/Istanbul', members: [], children: [ChildProfile(id: 'c1', firstName: 'Ela')]);

Widget _app(Widget home, {ChildApi? kid}) => ProviderScope(
      overrides: [
        if (kid != null) childApiProvider.overrideWithValue(kid),
        moodRepositoryProvider.overrideWithValue(_Moods()),
        familyProvider.overrideWith((ref, id) async => _family),
        meProvider.overrideWith((ref) async => const Me(id: 'u1', displayName: 'Ayşe', locale: 'tr', families: [FamilyRef(id: 'f1', name: 'Yılmaz')])),
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
        home: Scaffold(body: SingleChildScrollView(child: home)),
      ),
    );

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('the child picks a face and a reason and earns a cherry', (tester) async {
    _phone(tester);
    final api = _KidApi();
    await tester.pumpWidget(_app(const KidMoodCard(), kid: api));
    await tester.pumpAndSettle();

    expect(find.text('Bugün nasılsın?'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('mood.save'))).onPressed, isNull);
    await tester.tap(find.byKey(const Key('mood.Sad')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mood.reason.School')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mood.save')));
    await tester.pumpAndSettle();
    expect(api.calls, ['Sad School']);
    expect(find.text('Teşekkürler! +1 kiraz kazandın.'), findsOneWidget);
  });

  testWidgets('parents see the week, the trend and a gentle nudge', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(const SizedBox(height: 2000, child: MoodScreen(childId: 'c1'))));
    await tester.pumpAndSettle();

    expect(find.text('Ela · Duygular'), findsOneWidget);
    expect(find.byKey(const Key('mood.trend')), findsOneWidget);
    expect(find.text('Perşembe Ela "Üzgün" dedi · Okul'), findsOneWidget);
    expect(find.text('Akşam yemekte okulda nasıl geçtiğini sorabilirsin.'), findsOneWidget);
    expect(find.text('🙂 İyi · 2 gün'), findsOneWidget);
    expect(find.textContaining('bakıcı görmez'), findsOneWidget);
  });
}
