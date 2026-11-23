import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/api/api_client.dart';
import 'package:hally/core/auth/auth_repository.dart';
import 'package:hally/core/design/theme.dart';
import 'package:hally/features/family/family_repository.dart';
import 'package:hally/features/messages/chat_realtime.dart';
import 'package:hally/features/points/points_repository.dart';
import 'package:hally/features/points/points_screen.dart';
import 'package:hally/l10n/gen/app_localizations.dart';

const _me = Me(id: 'u1', displayName: 'Ayşe', locale: 'tr', families: [FamilyRef(id: 'f1', name: 'Yılmaz')]);
const _ela = ChildProfile(id: 'c1', firstName: 'Ela', color: 'mint');
const _can = ChildProfile(id: 'c2', firstName: 'Can', color: 'sky');

class _FakePoints implements PointsRepository {
  final calls = <String>[];
  final chores = <Chore>[const Chore(id: 'room', title: 'Odanı topla', points: 5), const Chore(id: 'cat', title: 'Kediyi besle', points: 2, childId: 'c2')];
  final rewards = <Reward>[const Reward(id: 'park', title: 'Parka gitmek', cost: 7)];
  final balance = <String, int>{'c1': 4, 'c2': 0};
  final ticked = <String, Map<String, String>>{'c1': {}, 'c2': {}};

  PointsBoard get _board => PointsBoard(
        chores: List.of(chores),
        rewards: List.of(rewards),
        children: [for (final c in ['c1', 'c2']) ChildPoints(childId: c, balance: balance[c]!, weekPoints: balance[c]!, doneToday: Map.of(ticked[c]!))],
      );

  @override
  Future<PointsBoard> board(String familyId) async => _board;

  @override
  Future<List<PointEntry>> history(String familyId, String childId) async =>
      [PointEntry(id: 'p1', kind: 'Chore', title: 'Odanı topla', points: 5, at: DateTime(2026, 11, 23, 9), byName: 'Ayşe')];

  @override
  Future<void> addChore(String familyId, {required String title, required int points, String? childId}) async => calls.add('chore $title $points ${childId ?? '-'}');

  @override
  Future<void> deleteChore(String familyId, String choreId) async {
    calls.add('delete chore $choreId');
    chores.removeWhere((c) => c.id == choreId);
  }

  @override
  Future<void> addReward(String familyId, {required String title, required int cost}) async => calls.add('reward $title $cost');

  @override
  Future<void> deleteReward(String familyId, String rewardId) async => calls.add('delete reward $rewardId');

  @override
  Future<PointsBoard> done(String familyId, String childId, String choreId) async {
    calls.add('done $childId $choreId');
    ticked[childId]![choreId] = 'e-$choreId';
    balance[childId] = balance[childId]! + chores.firstWhere((c) => c.id == choreId).points;
    return _board;
  }

  @override
  Future<PointsBoard> redeem(String familyId, String childId, String rewardId) async {
    calls.add('redeem $childId $rewardId');
    final cost = rewards.firstWhere((r) => r.id == rewardId).cost;
    if (balance[childId]! < cost) throw ApiException(422, 'points.not_enough', 'no');
    balance[childId] = balance[childId]! - cost;
    return _board;
  }

  @override
  Future<PointsBoard> undo(String familyId, String childId, String entryId) async {
    calls.add('undo $childId $entryId');
    ticked[childId]!.removeWhere((_, v) => v == entryId);
    return _board;
  }
}

Widget _app(_FakePoints repo) => ProviderScope(
      overrides: [
        meProvider.overrideWith((ref) async => _me),
        pointsRepositoryProvider.overrideWithValue(repo),
        chatRealtimeProvider.overrideWithValue(NoChatRealtime()),
        familyProvider.overrideWith((ref, id) async => const FamilyDetails(id: 'f1', name: 'Yılmaz', timeZoneId: 'Europe/Istanbul', members: [], children: [_ela, _can])),
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
        home: const PointsScreen(),
      ),
    );

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('ticking a chore earns stars and unlocks a reward', (tester) async {
    _phone(tester);
    final repo = _FakePoints();
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();
    expect(find.text('4 yıldız'), findsOneWidget);
    expect(find.text('Kediyi besle'), findsNothing); // Can's chore
    expect(find.text('3 yıldız daha lazım'), findsOneWidget);

    await tester.tap(find.byKey(const Key('points.done.room')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['done c1 room']);
    expect(find.text('9 yıldız'), findsOneWidget);

    await tester.tap(find.byKey(const Key('points.redeem.park')));
    await tester.pumpAndSettle();
    expect(repo.calls.last, 'redeem c1 park');
    expect(find.text('2 yıldız'), findsOneWidget);

    // Unticking undoes today's entry.
    await tester.tap(find.byKey(const Key('points.done.room')));
    await tester.pumpAndSettle();
    expect(repo.calls.last, 'undo c1 e-room');

    await tester.tap(find.byKey(const Key('points.child.c2')));
    await tester.pumpAndSettle();
    expect(find.text('Kediyi besle'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('adds a chore for one child and a reward', (tester) async {
    _phone(tester);
    final repo = _FakePoints();
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('points.add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('points.save')));
    await tester.pumpAndSettle();
    expect(find.text('Bir ad yazın.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('points.title')), 'Sofrayı kur');
    await tester.tap(find.byKey(const Key('points.plus')));
    await tester.tap(find.text('Ela').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('points.save')));
    await tester.pumpAndSettle();
    expect(repo.calls, ['chore Sofrayı kur 6 c1']);

    await tester.tap(find.byKey(const Key('points.add')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ödül'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('points.title')), '20 TL harçlık');
    await tester.tap(find.byKey(const Key('points.plus')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('points.save')));
    await tester.pumpAndSettle();
    expect(repo.calls.last, 'reward 20 TL harçlık 25');

    await tester.tap(find.byKey(const Key('points.history')));
    await tester.pumpAndSettle();
    expect(find.text('+5'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
