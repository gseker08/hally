import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/auth/auth_repository.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/features/family/family_repository.dart';
import 'package:hally/features/feeding/feeding_repository.dart';
import 'package:hally/features/feeding/feeding_screen.dart';
import 'package:hally/features/messages/chat_realtime.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

const _me = Me(id: 'u1', displayName: 'Ayşe', locale: 'tr', families: [FamilyRef(id: 'f1', name: 'Yılmaz')]);
const _can = ChildProfile(id: 'c1', firstName: 'Can', color: 'mint');

class _FakeFeeding implements FeedingRepository {
  final calls = <String>[];
  final entries = <FeedingEntry>[];
  String? nextSide;

  ChildFeedingStatus get _status => ChildFeedingStatus(
        childId: 'c1',
        last: entries.isEmpty ? null : entries.first,
        nextSide: nextSide,
        feedsToday: entries.length,
        bottleMlToday: entries.fold(0, (a, e) => a + (e.amountMl ?? 0)),
      );

  @override
  Future<List<ChildFeedingStatus>> status(String familyId) async => [_status];

  @override
  Future<FeedingHistory> history(String familyId, String childId) async => FeedingHistory(
        days: [for (var i = 0; i < 3; i++) FeedingDay(date: DateTime(2026, 11, 21 + i), feeds: i == 2 ? entries.length : 0)],
        entries: entries,
      );

  @override
  Future<ChildFeedingStatus> add(String familyId, String childId,
      {required String kind, DateTime? at, String? side, int? minutes, int? amountMl, String? food, String? note}) async {
    calls.add([kind, side, minutes, amountMl, food].whereType<Object>().join(' '));
    entries.insert(0, FeedingEntry(id: 'e${entries.length}', childId: childId, kind: kind, at: DateTime.now(), side: side, minutes: minutes, amountMl: amountMl, food: food));
    if (kind == 'Breast') nextSide = side == 'Left' ? 'Right' : side == 'Right' ? 'Left' : null;
    return _status;
  }

  @override
  Future<void> delete(String familyId, String childId, String entryId) async {
    calls.add('delete $entryId');
    entries.removeWhere((e) => e.id == entryId);
  }
}

Widget _app(_FakeFeeding repo) => ProviderScope(
      overrides: [
        meProvider.overrideWith((ref) async => _me),
        feedingRepositoryProvider.overrideWithValue(repo),
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
        home: const FeedingScreen(),
      ),
    );

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  test('time since the last feed reads naturally', () {
    final now = DateTime(2026, 11, 23, 12);
    expect(feedingAgo(now.subtract(const Duration(minutes: 45)), now, lang: 'tr'), '45 dk');
    expect(feedingAgo(now.subtract(const Duration(minutes: 130)), now, lang: 'en'), '2 h 10 min');
  });

  testWidgets('a breast feed then a bottle show the last feed, next side and today', (tester) async {
    _phone(tester);
    final repo = _FakeFeeding();
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();
    expect(find.text('Henüz kayıt yok'), findsOneWidget);

    await tester.tap(find.byKey(const Key('feeding.add.Breast.c1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('feeding.minutes.plus')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('feeding.save')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['Breast Left 20']);
    expect(find.text('Sıradaki taraf: Sağ'), findsOneWidget);

    await tester.tap(find.byKey(const Key('feeding.add.Bottle.c1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('feeding.ml.minus')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('feeding.save')));
    await tester.pumpAndSettle();
    expect(repo.calls.last, 'Bottle 110');
    expect(find.text('0 dk önce · Biberon · 110 ml'), findsOneWidget);
    expect(find.text('Bugün 2 öğün · 110 ml biberon'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('solids need a food, and the history deletes a feed', (tester) async {
    _phone(tester);
    final repo = _FakeFeeding();
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('feeding.add.Solid.c1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('feeding.save')));
    await tester.pumpAndSettle();
    expect(find.text('Ne yediğini yazın.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('feeding.food')), 'Havuç püresi');
    await tester.tap(find.byKey(const Key('feeding.save')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['Solid Havuç püresi']);

    await tester.tap(find.byKey(const Key('feeding.line.c1')));
    await tester.pumpAndSettle();
    expect(find.text('Ek gıda · Havuç püresi'), findsOneWidget);
    await tester.tap(find.byKey(const Key('feeding.delete.e0')));
    await tester.pumpAndSettle();
    expect(repo.calls.last, 'delete e0');
    await tester.pumpWidget(const SizedBox());
  });
}
