import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../insights/insights_repository.dart' show insightsDay;

int _i(Object? v) => (v as num?)?.toInt() ?? 0;

/// What one adult marked done in Hally in the range.
class BalanceMember {
  const BalanceMember({
    required this.userId,
    required this.name,
    required this.role,
    this.tasks = 0,
    this.schoolRuns = 0,
    this.feedings = 0,
    this.shopping = 0,
    this.medications = 0,
  });

  factory BalanceMember.fromJson(Map<String, dynamic> j) => BalanceMember(
        userId: j['userId'] as String,
        name: j['name'] as String,
        role: j['role'] as String,
        tasks: _i(j['tasks']),
        schoolRuns: _i(j['schoolRuns']),
        feedings: _i(j['feedings']),
        shopping: _i(j['shopping']),
        medications: _i(j['medications']),
      );

  final String userId;
  final String name;

  /// "Parent" or "Caregiver".
  final String role;
  final int tasks;
  final int schoolRuns;
  final int feedings;
  final int shopping;
  final int medications;

  bool get isCaregiver => role == 'Caregiver';
  int get total => tasks + schoolRuns + feedings + shopping + medications;

  /// In the order the chart stacks them.
  List<int> get parts => [tasks, schoolRuns, feedings, shopping, medications];
}

/// "Ayşe did 80% this week; Mehmet could take Thursday's pick-up."
class BalanceSuggestion {
  const BalanceSuggestion({required this.heavyUserId, required this.heavyName, required this.sharePercent, required this.toUserId, required this.toName, this.date, this.kind});

  factory BalanceSuggestion.fromJson(Map<String, dynamic> j) => BalanceSuggestion(
        heavyUserId: j['heavyUserId'] as String,
        heavyName: j['heavyName'] as String,
        sharePercent: _i(j['sharePercent']),
        toUserId: j['toUserId'] as String,
        toName: j['toName'] as String,
        date: j['date'] == null ? null : DateTime.parse(j['date'] as String),
        kind: j['kind'] as String?,
      );

  final String heavyUserId;
  final String heavyName;
  final int sharePercent;
  final String toUserId;
  final String toName;

  /// The next school run planned for the heavy parent, if any.
  final DateTime? date;

  /// "DropOff" or "PickUp".
  final String? kind;
}

class FamilyBalance {
  const FamilyBalance({required this.from, required this.to, required this.today, required this.members, this.suggestion});

  factory FamilyBalance.fromJson(Map<String, dynamic> j) => FamilyBalance(
        from: DateTime.parse(j['from'] as String),
        to: DateTime.parse(j['to'] as String),
        today: DateTime.parse(j['today'] as String),
        members: [for (final m in j['members'] as List) BalanceMember.fromJson(m as Map<String, dynamic>)],
        suggestion: j['suggestion'] == null ? null : BalanceSuggestion.fromJson(j['suggestion'] as Map<String, dynamic>),
      );

  final DateTime from;
  final DateTime to;
  final DateTime today;
  final List<BalanceMember> members;
  final BalanceSuggestion? suggestion;

  int get total => members.fold(0, (a, m) => a + m.total);
}

abstract interface class BalanceRepository {
  /// Null dates mean this week (Monday to today, family time).
  Future<FamilyBalance> balance(String familyId, {DateTime? from, DateTime? to});
}

class ApiBalanceRepository implements BalanceRepository {
  ApiBalanceRepository(this._api);

  final ApiClient _api;

  @override
  Future<FamilyBalance> balance(String familyId, {DateTime? from, DateTime? to}) async {
    try {
      final res = await _api.dio.get<Map<String, dynamic>>('/api/v1/families/$familyId/balance', queryParameters: {
        if (from != null) 'from': insightsDay(from),
        if (to != null) 'to': insightsDay(to),
      });
      return FamilyBalance.fromJson(res.data!);
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }
}

final balanceRepositoryProvider = Provider<BalanceRepository>((ref) => ApiBalanceRepository(ref.watch(apiClientProvider)));

/// Which weeks the balance page shows.
enum BalanceRange { thisWeek, lastWeek, fourWeeks }

/// (familyId, range). The ranges are worked out from the device's today; the server clamps "today" to family time.
final familyBalanceProvider = FutureProvider.autoDispose.family<FamilyBalance, (String, BalanceRange)>((ref, key) {
  final repo = ref.watch(balanceRepositoryProvider);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final monday = today.subtract(Duration(days: today.weekday - 1));
  return switch (key.$2) {
    BalanceRange.thisWeek => repo.balance(key.$1),
    BalanceRange.lastWeek => repo.balance(key.$1, from: monday.subtract(const Duration(days: 7)), to: monday.subtract(const Duration(days: 1))),
    BalanceRange.fourWeeks => repo.balance(key.$1, from: monday.subtract(const Duration(days: 21)), to: today),
  };
});
