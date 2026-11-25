import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/api/api_client.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/features/activities/activities.dart';
import 'package:hally/features/activities/activity_screens.dart';
import 'package:hally/features/child_mode/child_mode_repository.dart';
import 'package:hally/features/child_mode/kid_screens.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

const _bike = ActivityIdea(id: 'a1', emoji: '🚲', title: 'Bisiklete bin', hint: 'Kaskını unutma', place: 'Outdoor', minutes: 30, cherries: 3);
const _lego = ActivityIdea(id: 'a2', emoji: '🧱', title: 'Legodan köprü yap', hint: 'Fotoğrafını ailene göster', place: 'Indoor', minutes: 30, cherries: 3);
const _book = ActivityIdea(id: 'a3', emoji: '📚', title: '15 dk kitap oku', place: 'Indoor', cherries: 5);

class _KidApi implements ChildApi {
  _KidApi({this.limitAfter = 99});

  final int limitAfter;
  final calls = <String>[];
  var current = const ChildActivities(
    weather: ActivityWeather(temperatureC: 14, sky: 'Clear'),
    weatherPlace: 'Ankara',
    age: 8,
    ideas: [_bike, _lego, _book],
  );

  @override
  Future<ChildActivities> activities(String lang) async {
    calls.add('list $lang');
    return current;
  }

  @override
  Future<ChildActivities> activityDone(String id, String lang) async {
    calls.add('done $id');
    if (calls.where((c) => c.startsWith('done')).length > limitAfter) throw ApiException(422, 'activity.daily_limit', 'limit');
    current = ChildActivities(
      weather: current.weather,
      age: current.age,
      doneToday: current.doneToday + 1,
      ideas: [
        for (final i in current.ideas)
          i.id == id ? ActivityIdea(id: i.id, emoji: i.emoji, title: i.title, place: i.place, cherries: i.cherries, state: 'Pending') : i,
      ],
    );
    return current;
  }

  @override
  Future<ChildHome> home() async => const ChildHome(
        childId: 'c1',
        firstName: 'Ela',
        color: 'cherry',
        familyName: 'Yılmaz',
        balance: 4,
        weekCherries: 4,
        streakDays: 1,
        nextBonusIn: 6,
        today: [],
        rewards: [ChildReward(id: 'r1', title: '15 dk ekstra ekran', cost: 20, screenMinutes: 15)],
        screen: ChildScreen(goalMinutes: 60, limitMinutes: 60, usedSeconds: 3600, locked: true),
        todayMood: 'Good',
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Repo implements ActivitiesRepository {
  final calls = <String>[];
  var data = const FamilyActivities(builtIn: 26);

  @override
  Future<FamilyActivities> load(String familyId) async => data;

  @override
  Future<void> add(String familyId, {required String title, required String emoji, required int cherries, required bool outdoor}) async {
    calls.add('add $title $emoji $cherries $outdoor');
    data = FamilyActivities(
        place: data.place, builtIn: 26, own: [OwnActivity(id: 'o1', emoji: emoji, title: title, place: outdoor ? 'Outdoor' : 'Indoor', cherries: cherries)]);
  }

  @override
  Future<void> delete(String familyId, String id) async {
    calls.add('delete $id');
    data = FamilyActivities(place: data.place, builtIn: 26);
  }

  @override
  Future<void> setPlace(String familyId, WeatherPlace? place) async {
    calls.add('place ${place?.name}');
    data = FamilyActivities(place: place, own: data.own, builtIn: 26);
  }

  @override
  Future<List<WeatherPlace>> searchPlaces(String query, String lang) async =>
      [const WeatherPlace(name: 'Ankara', region: 'Ankara', country: 'Türkiye', latitude: 39.9, longitude: 32.9)];
}

Widget _app(Widget home, {ChildApi? kid, ActivitiesRepository? repo}) => ProviderScope(
      overrides: [
        if (kid != null) childApiProvider.overrideWithValue(kid),
        if (repo != null) activitiesRepositoryProvider.overrideWithValue(repo),
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

void _phone(WidgetTester tester, {Size size = const Size(1080, 2340)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('the lock page opens the ideas, and "Yaptım" waits for a parent', (tester) async {
    _phone(tester);
    final api = _KidApi();
    await tester.pumpWidget(_app(const KidShell(), kid: api));
    await tester.pumpAndSettle();

    expect(find.text('Ekran süren doldu'), findsOneWidget);
    expect(find.text('Şimdi ne yapsam?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('kid.lock.ideas')));
    await tester.pumpAndSettle();

    expect(api.calls, ['list tr']);
    expect(find.text('☀️ 14° Güneşli'), findsOneWidget);
    expect(find.text('🎂 8 yaş'), findsOneWidget);
    expect(find.text('Bugün 0/3'), findsOneWidget);
    expect(find.text('Dışarıda · Kaskını unutma'), findsOneWidget);

    // "Başka fikir" moves to the next idea; "Yaptım" sends it.
    await tester.tap(find.text('Bisiklete bin'));
    await tester.pumpAndSettle();
    expect(find.text('Bitirince "Yaptım"a bas, ailen onaylasın.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('act.another')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(BottomSheet), matching: find.text('Legodan köprü yap')), findsOneWidget);
    await tester.tap(find.byKey(const Key('act.do')));
    await tester.pumpAndSettle();

    expect(api.calls.last, 'done a2');
    expect(find.text('Harika! Ailen onaylayınca kirazların gelecek.'), findsOneWidget);
    expect(find.text('Onay bekliyor'), findsOneWidget);
    expect(find.text('Bugün 1/3'), findsOneWidget);

    // A waiting idea cannot be sent again.
    await tester.tap(find.text('Legodan köprü yap'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byKey(const Key('act.do'))).onPressed, isNull);
  });

  testWidgets('the daily limit shows a friendly message', (tester) async {
    _phone(tester);
    final api = _KidApi(limitAfter: 0);
    await tester.pumpWidget(_app(const KidActivitiesScreen(requireApproval: true), kid: api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('15 dk kitap oku'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('act.do')));
    await tester.pumpAndSettle();
    expect(find.text('Bugünlük bu kadar. Yarın yeni fikirler var!'), findsOneWidget);
  });

  testWidgets('the lock page fits a small phone', (tester) async {
    _phone(tester, size: const Size(720, 1280));
    await tester.pumpWidget(_app(const KidShell(), kid: _KidApi()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.byKey(const Key('kid.lock.ask')), 200);
    expect(find.byKey(const Key('kid.lock.ask')), findsOneWidget);
  });

  testWidgets('a parent picks the city and adds and deletes an idea', (tester) async {
    _phone(tester);
    final repo = _Repo();
    await tester.pumpWidget(_app(const FamilyActivitiesScreen(familyId: 'f1'), repo: repo));
    await tester.pumpAndSettle();

    expect(find.text('Seçilmedi'), findsOneWidget);
    expect(find.textContaining("Hally'nin 26 hazır fikri"), findsOneWidget);

    await tester.tap(find.byKey(const Key('act.city')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('act.city.query')), 'Ank');
    await tester.tap(find.byKey(const Key('act.city.search')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('act.city.Ankara')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['place Ankara']);
    expect(find.text('Ankara'), findsOneWidget);

    await tester.tap(find.byKey(const Key('act.add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('act.add.title')), 'Dedeye telefon et');
    await tester.tap(find.text('☎️'));
    await tester.tap(find.byKey(const Key('act.add.cherries.5')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('act.add.save')));
    await tester.pumpAndSettle();
    expect(repo.calls.last, 'add Dedeye telefon et ☎️ 5 false');
    expect(find.text('Dedeye telefon et'), findsOneWidget);

    await tester.tap(find.byKey(const Key('act.own.delete.o1')));
    await tester.pumpAndSettle();
    expect(repo.calls.last, 'delete o1');
    expect(find.text('Dedeye telefon et'), findsNothing);
  });
}
