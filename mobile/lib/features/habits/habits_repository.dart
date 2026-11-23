import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../messages/chat_realtime.dart';

const everyDay = 0x7f;

class Habit {
  const Habit({
    required this.id,
    required this.childId,
    required this.title,
    this.days = everyDay,
    this.doneToday = false,
    this.dueToday = true,
    this.streak = 0,
    this.best = 0,
    this.lastSeven = const [],
  });

  factory Habit.fromJson(Map<String, dynamic> j) => Habit(
        id: j['id'] as String,
        childId: j['childId'] as String,
        title: j['title'] as String,
        days: j['days'] as int? ?? everyDay,
        doneToday: j['doneToday'] as bool? ?? false,
        dueToday: j['dueToday'] as bool? ?? true,
        streak: j['streak'] as int? ?? 0,
        best: j['best'] as int? ?? 0,
        lastSeven: [for (final d in j['lastSeven'] as List? ?? const []) d as bool?],
      );

  final String id;
  final String childId;
  final String title;

  /// Weekday mask, Monday bit 0.
  final int days;
  final bool doneToday;
  final bool dueToday;
  final int streak;
  final int best;

  /// Oldest first, ending today: true done, false not done, null not scheduled.
  final List<bool?> lastSeven;
}

class HabitsBoard {
  const HabitsBoard({required this.today, this.habits = const []});

  factory HabitsBoard.fromJson(Map<String, dynamic> j) => HabitsBoard(
        today: DateTime.parse(j['today'] as String),
        habits: [for (final h in j['habits'] as List) Habit.fromJson(h as Map<String, dynamic>)],
      );

  final DateTime today;
  final List<Habit> habits;
}

String _day(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

abstract interface class HabitsRepository {
  Future<HabitsBoard> list(String familyId);
  Future<HabitsBoard> add(String familyId, {required String childId, required String title, int days = everyDay});
  Future<HabitsBoard> delete(String familyId, String habitId);
  Future<HabitsBoard> check(String familyId, String habitId, DateTime day);
  Future<HabitsBoard> uncheck(String familyId, String habitId, DateTime day);
}

class ApiHabitsRepository implements HabitsRepository {
  ApiHabitsRepository(this._api);

  final ApiClient _api;

  Future<HabitsBoard> _board(Future<dynamic> Function() fn) async {
    try {
      return HabitsBoard.fromJson((await fn()).data as Map<String, dynamic>);
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }

  String _u(String familyId) => '/api/v1/families/$familyId/habits';

  @override
  Future<HabitsBoard> list(String familyId) => _board(() => _api.dio.get<Map<String, dynamic>>(_u(familyId)));

  @override
  Future<HabitsBoard> add(String familyId, {required String childId, required String title, int days = everyDay}) =>
      _board(() => _api.dio.post<Map<String, dynamic>>(_u(familyId), data: {'childId': childId, 'title': title, 'days': days}));

  @override
  Future<HabitsBoard> delete(String familyId, String habitId) => _board(() => _api.dio.delete<Map<String, dynamic>>('${_u(familyId)}/$habitId'));

  @override
  Future<HabitsBoard> check(String familyId, String habitId, DateTime day) =>
      _board(() => _api.dio.post<Map<String, dynamic>>('${_u(familyId)}/$habitId/check', data: {'day': _day(day)}));

  @override
  Future<HabitsBoard> uncheck(String familyId, String habitId, DateTime day) =>
      _board(() => _api.dio.delete<Map<String, dynamic>>('${_u(familyId)}/$habitId/check', queryParameters: {'day': _day(day)}));
}

final habitsRepositoryProvider = Provider<HabitsRepository>((ref) => ApiHabitsRepository(ref.watch(apiClientProvider)));

/// Every habit of the family; follows the other parent's taps live.
final habitsProvider = FutureProvider.autoDispose.family<HabitsBoard, String>((ref, familyId) async {
  final live = ref.watch(chatRealtimeProvider).habitsEvents.where((e) => e['familyId'] == familyId).listen((_) => ref.invalidateSelf());
  ref.onDispose(live.cancel);
  return ref.watch(habitsRepositoryProvider).list(familyId);
});
