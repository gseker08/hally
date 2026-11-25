import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';

class GoalContributor {
  const GoalContributor({required this.kind, required this.id, required this.name, this.color, required this.cherries});

  factory GoalContributor.fromJson(Map<String, dynamic> j) => GoalContributor(
        kind: j['kind'] as String,
        id: j['id'] as String,
        name: j['name'] as String,
        color: j['color'] as String?,
        cherries: (j['cherries'] as num).toInt(),
      );

  /// Child or Adult.
  final String kind;
  final String id;
  final String name;
  final String? color;
  final int cherries;

  bool get isChild => kind == 'Child';
}

class FamilyGoal {
  const FamilyGoal({
    required this.id,
    required this.weekEnd,
    required this.daysLeft,
    required this.rewardTitle,
    required this.rewardEmoji,
    required this.target,
    required this.total,
    this.repeat = false,
    this.reachedAt,
    this.contributors = const [],
  });

  factory FamilyGoal.fromJson(Map<String, dynamic> j) => FamilyGoal(
        id: j['id'] as String,
        weekEnd: DateTime.parse(j['weekEnd'] as String),
        daysLeft: (j['daysLeft'] as num).toInt(),
        rewardTitle: j['rewardTitle'] as String,
        rewardEmoji: j['rewardEmoji'] as String,
        target: (j['target'] as num).toInt(),
        total: (j['total'] as num).toInt(),
        repeat: j['repeat'] as bool? ?? false,
        reachedAt: j['reachedAt'] == null ? null : DateTime.parse(j['reachedAt'] as String),
        contributors: [for (final c in j['contributors'] as List? ?? const []) GoalContributor.fromJson(c as Map<String, dynamic>)],
      );

  final String id;
  final DateTime weekEnd;
  final int daysLeft;
  final String rewardTitle;
  final String rewardEmoji;
  final int target;
  final int total;
  final bool repeat;
  final DateTime? reachedAt;
  final List<GoalContributor> contributors;

  bool get reached => reachedAt != null || total >= target;
  int get missing => (target - total).clamp(0, target);
  double get progress => target == 0 ? 0 : (total / target).clamp(0.0, 1.0);
}

class FamilyGoalState {
  const FamilyGoalState({this.goal, this.lastWeekTotal = 0, this.suggestedTarget = 80});

  factory FamilyGoalState.fromJson(Map<String, dynamic> j) => FamilyGoalState(
        goal: j['goal'] == null ? null : FamilyGoal.fromJson(j['goal'] as Map<String, dynamic>),
        lastWeekTotal: (j['lastWeekTotal'] as num?)?.toInt() ?? 0,
        suggestedTarget: (j['suggestedTarget'] as num?)?.toInt() ?? 80,
      );

  final FamilyGoal? goal;
  final int lastWeekTotal;
  final int suggestedTarget;
}

abstract interface class FamilyGoalRepository {
  Future<FamilyGoalState> load(String familyId);
  Future<FamilyGoalState> set(String familyId, {required String rewardTitle, required String rewardEmoji, required int target, required bool repeat});
  Future<FamilyGoalState> end(String familyId);
}

class ApiFamilyGoalRepository implements FamilyGoalRepository {
  ApiFamilyGoalRepository(this._api);

  final ApiClient _api;

  Future<FamilyGoalState> _state(Future<dynamic> Function() fn) async {
    try {
      final res = await fn();
      return FamilyGoalState.fromJson(res.data as Map<String, dynamic>);
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }

  String _url(String familyId) => '/api/v1/families/$familyId/goal';

  @override
  Future<FamilyGoalState> load(String familyId) => _state(() => _api.dio.get<Map<String, dynamic>>(_url(familyId)));

  @override
  Future<FamilyGoalState> set(String familyId, {required String rewardTitle, required String rewardEmoji, required int target, required bool repeat}) =>
      _state(() => _api.dio
          .put<Map<String, dynamic>>(_url(familyId), data: {'rewardTitle': rewardTitle, 'rewardEmoji': rewardEmoji, 'target': target, 'repeat': repeat}));

  @override
  Future<FamilyGoalState> end(String familyId) => _state(() => _api.dio.delete<Map<String, dynamic>>(_url(familyId)));
}

final familyGoalRepositoryProvider = Provider<FamilyGoalRepository>((ref) => ApiFamilyGoalRepository(ref.watch(apiClientProvider)));

final familyGoalProvider =
    FutureProvider.autoDispose.family<FamilyGoalState, String>((ref, familyId) => ref.watch(familyGoalRepositoryProvider).load(familyId));
