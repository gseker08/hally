import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../messages/chat_realtime.dart';

class Chore {
  const Chore({required this.id, required this.title, required this.points, this.childId});

  factory Chore.fromJson(Map<String, dynamic> j) =>
      Chore(id: j['id'] as String, title: j['title'] as String, points: j['points'] as int, childId: j['childId'] as String?);

  final String id;
  final String title;
  final int points;

  /// Null: any child.
  final String? childId;

  bool isFor(String child) => childId == null || childId == child;
}

class Reward {
  const Reward({required this.id, required this.title, required this.cost});

  factory Reward.fromJson(Map<String, dynamic> j) => Reward(id: j['id'] as String, title: j['title'] as String, cost: j['cost'] as int);

  final String id;
  final String title;
  final int cost;
}

class ChildPoints {
  const ChildPoints({required this.childId, this.balance = 0, this.weekPoints = 0, this.doneToday = const {}});

  factory ChildPoints.fromJson(Map<String, dynamic> j) => ChildPoints(
        childId: j['childId'] as String,
        balance: j['balance'] as int? ?? 0,
        weekPoints: j['weekPoints'] as int? ?? 0,
        doneToday: {for (final e in (j['doneToday'] as Map? ?? {}).entries) e.key as String: e.value as String},
      );

  final String childId;
  final int balance;
  final int weekPoints;

  /// Chore id → ledger entry id (to undo).
  final Map<String, String> doneToday;
}

class PointsBoard {
  const PointsBoard({this.chores = const [], this.rewards = const [], this.children = const []});

  factory PointsBoard.fromJson(Map<String, dynamic> j) => PointsBoard(
        chores: [for (final c in j['chores'] as List) Chore.fromJson(c as Map<String, dynamic>)],
        rewards: [for (final r in j['rewards'] as List) Reward.fromJson(r as Map<String, dynamic>)],
        children: [for (final c in j['children'] as List) ChildPoints.fromJson(c as Map<String, dynamic>)],
      );

  final List<Chore> chores;
  final List<Reward> rewards;
  final List<ChildPoints> children;

  ChildPoints of(String childId) => children.firstWhere((c) => c.childId == childId, orElse: () => ChildPoints(childId: childId));
}

class PointEntry {
  const PointEntry({required this.id, required this.kind, required this.title, required this.points, required this.at, this.byName});

  factory PointEntry.fromJson(Map<String, dynamic> j) => PointEntry(
        id: j['id'] as String,
        kind: j['kind'] as String,
        title: j['title'] as String,
        points: j['points'] as int,
        at: DateTime.parse(j['at'] as String).toLocal(),
        byName: j['byName'] as String?,
      );

  final String id;

  /// "Chore" or "Reward".
  final String kind;
  final String title;
  final int points;
  final DateTime at;
  final String? byName;
}

abstract interface class PointsRepository {
  Future<PointsBoard> board(String familyId);
  Future<List<PointEntry>> history(String familyId, String childId);
  Future<void> addChore(String familyId, {required String title, required int points, String? childId});
  Future<void> deleteChore(String familyId, String choreId);
  Future<void> addReward(String familyId, {required String title, required int cost});
  Future<void> deleteReward(String familyId, String rewardId);
  Future<PointsBoard> done(String familyId, String childId, String choreId);
  Future<PointsBoard> redeem(String familyId, String childId, String rewardId);
  Future<PointsBoard> undo(String familyId, String childId, String entryId);
}

class ApiPointsRepository implements PointsRepository {
  ApiPointsRepository(this._api);

  final ApiClient _api;

  Future<T> _call<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }

  String _f(String familyId) => '/api/v1/families/$familyId';

  Future<PointsBoard> _board(Future<dynamic> request) async => PointsBoard.fromJson(((await request) as dynamic).data as Map<String, dynamic>);

  @override
  Future<PointsBoard> board(String familyId) => _call(() => _board(_api.dio.get<Map<String, dynamic>>('${_f(familyId)}/points')));

  @override
  Future<List<PointEntry>> history(String familyId, String childId) => _call(() async {
        final res = await _api.dio.get<List<dynamic>>('${_f(familyId)}/children/$childId/points');
        return [for (final e in res.data!) PointEntry.fromJson(e as Map<String, dynamic>)];
      });

  @override
  Future<void> addChore(String familyId, {required String title, required int points, String? childId}) =>
      _call(() => _api.dio.post<dynamic>('${_f(familyId)}/chores', data: {'title': title, 'points': points, 'childId': childId}));

  @override
  Future<void> deleteChore(String familyId, String choreId) => _call(() => _api.dio.delete<dynamic>('${_f(familyId)}/chores/$choreId'));

  @override
  Future<void> addReward(String familyId, {required String title, required int cost}) =>
      _call(() => _api.dio.post<dynamic>('${_f(familyId)}/rewards', data: {'title': title, 'cost': cost}));

  @override
  Future<void> deleteReward(String familyId, String rewardId) => _call(() => _api.dio.delete<dynamic>('${_f(familyId)}/rewards/$rewardId'));

  @override
  Future<PointsBoard> done(String familyId, String childId, String choreId) =>
      _call(() => _board(_api.dio.post<Map<String, dynamic>>('${_f(familyId)}/children/$childId/chores/$choreId/done')));

  @override
  Future<PointsBoard> redeem(String familyId, String childId, String rewardId) =>
      _call(() => _board(_api.dio.post<Map<String, dynamic>>('${_f(familyId)}/children/$childId/rewards/$rewardId/redeem')));

  @override
  Future<PointsBoard> undo(String familyId, String childId, String entryId) =>
      _call(() => _board(_api.dio.delete<Map<String, dynamic>>('${_f(familyId)}/children/$childId/points/$entryId')));
}

final pointsRepositoryProvider = Provider<PointsRepository>((ref) => ApiPointsRepository(ref.watch(apiClientProvider)));

/// The family's chores, rewards and stars; follows the other parent's changes live.
final pointsBoardProvider = FutureProvider.autoDispose.family<PointsBoard, String>((ref, familyId) async {
  final live = ref.watch(chatRealtimeProvider).pointsEvents.where((e) => e['familyId'] == familyId).listen((_) => ref.invalidateSelf());
  ref.onDispose(live.cancel);
  return ref.watch(pointsRepositoryProvider).board(familyId);
});

final pointsHistoryProvider = FutureProvider.autoDispose.family<List<PointEntry>, (String, String)>((ref, key) async {
  final live = ref.watch(chatRealtimeProvider).pointsEvents.where((e) => e['familyId'] == key.$1).listen((_) => ref.invalidateSelf());
  ref.onDispose(live.cancel);
  return ref.watch(pointsRepositoryProvider).history(key.$1, key.$2);
});
