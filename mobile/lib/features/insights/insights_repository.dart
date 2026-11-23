import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';

int _i(Object? v) => (v as num?)?.toInt() ?? 0;
double? _d(Object? v) => (v as num?)?.toDouble();

String insightsDay(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class InsightDay {
  const InsightDay({
    required this.date,
    this.screenMinutes = 0,
    this.homeworkMinutes = 0,
    this.readingMinutes = 0,
    this.nightSleepMinutes = 0,
    this.napMinutes = 0,
    this.feeds = 0,
    this.bottleMl = 0,
    this.breastMinutes = 0,
    this.solids = 0,
    this.starsEarned = 0,
    this.starsSpent = 0,
    this.habitsDone = 0,
    this.habitsScheduled = 0,
    this.doses = 0,
  });

  factory InsightDay.fromJson(Map<String, dynamic> j) => InsightDay(
        date: DateTime.parse(j['date'] as String),
        screenMinutes: _i(j['screenMinutes']),
        homeworkMinutes: _i(j['homeworkMinutes']),
        readingMinutes: _i(j['readingMinutes']),
        nightSleepMinutes: _i(j['nightSleepMinutes']),
        napMinutes: _i(j['napMinutes']),
        feeds: _i(j['feeds']),
        bottleMl: _i(j['bottleMl']),
        breastMinutes: _i(j['breastMinutes']),
        solids: _i(j['solids']),
        starsEarned: _i(j['starsEarned']),
        starsSpent: _i(j['starsSpent']),
        habitsDone: _i(j['habitsDone']),
        habitsScheduled: _i(j['habitsScheduled']),
        doses: _i(j['doses']),
      );

  final DateTime date;
  final int screenMinutes;
  final int homeworkMinutes;
  final int readingMinutes;
  final int nightSleepMinutes;
  final int napMinutes;
  final int feeds;
  final int bottleMl;
  final int breastMinutes;
  final int solids;
  final int starsEarned;
  final int starsSpent;
  final int habitsDone;
  final int habitsScheduled;
  final int doses;

  int get studyMinutes => homeworkMinutes + readingMinutes;
  int get sleepMinutes => nightSleepMinutes + napMinutes;
}

class HabitInsight {
  const HabitInsight({required this.id, required this.title, this.streak = 0, this.best = 0, this.done = 0, this.scheduled = 0});

  factory HabitInsight.fromJson(Map<String, dynamic> j) => HabitInsight(
      id: j['id'] as String, title: j['title'] as String, streak: _i(j['streak']), best: _i(j['best']), done: _i(j['done']), scheduled: _i(j['scheduled']));

  final String id;
  final String title;
  final int streak;
  final int best;
  final int done;
  final int scheduled;
}

class MedicationInsight {
  const MedicationInsight({required this.id, required this.name, this.doses = 0});

  factory MedicationInsight.fromJson(Map<String, dynamic> j) => MedicationInsight(id: j['id'] as String, name: j['name'] as String, doses: _i(j['doses']));

  final String id;
  final String name;
  final int doses;
}

class HealthSnapshot {
  const HealthSnapshot({this.heightCm, this.weightKg, this.measuredOn, this.vaccinesOverdue = 0, this.vaccinesDueSoon = 0, this.nextAppointment, this.nextAppointmentAt, this.hasAllergies = false});

  factory HealthSnapshot.fromJson(Map<String, dynamic> j) => HealthSnapshot(
        heightCm: _d(j['heightCm']),
        weightKg: _d(j['weightKg']),
        measuredOn: j['measuredOn'] == null ? null : DateTime.parse(j['measuredOn'] as String),
        vaccinesOverdue: _i(j['vaccinesOverdue']),
        vaccinesDueSoon: _i(j['vaccinesDueSoon']),
        nextAppointment: j['nextAppointment'] as String?,
        nextAppointmentAt: j['nextAppointmentAt'] == null ? null : DateTime.parse(j['nextAppointmentAt'] as String).toLocal(),
        hasAllergies: j['hasAllergies'] as bool? ?? false,
      );

  final double? heightCm;
  final double? weightKg;
  final DateTime? measuredOn;
  final int vaccinesOverdue;
  final int vaccinesDueSoon;
  final String? nextAppointment;
  final DateTime? nextAppointmentAt;
  final bool hasAllergies;

  bool get isEmpty => heightCm == null && weightKg == null && vaccinesOverdue == 0 && vaccinesDueSoon == 0 && nextAppointment == null && !hasAllergies;
}

class ChildInsights {
  const ChildInsights({
    required this.childId,
    required this.from,
    required this.to,
    required this.today,
    this.screenGoalMinutes,
    this.studyGoalMinutes,
    this.days = const [],
    this.habits = const [],
    this.medications = const [],
    this.starBalance = 0,
    this.expensesTotal = 0,
    this.health = const HealthSnapshot(),
  });

  factory ChildInsights.fromJson(Map<String, dynamic> j) => ChildInsights(
        childId: j['childId'] as String,
        from: DateTime.parse(j['from'] as String),
        to: DateTime.parse(j['to'] as String),
        today: DateTime.parse(j['today'] as String),
        screenGoalMinutes: (j['screenGoalMinutes'] as num?)?.toInt(),
        studyGoalMinutes: (j['studyGoalMinutes'] as num?)?.toInt(),
        days: [for (final d in j['days'] as List) InsightDay.fromJson(d as Map<String, dynamic>)],
        habits: [for (final h in j['habits'] as List) HabitInsight.fromJson(h as Map<String, dynamic>)],
        medications: [for (final m in j['medications'] as List) MedicationInsight.fromJson(m as Map<String, dynamic>)],
        starBalance: _i(j['starBalance']),
        expensesTotal: _d(j['expensesTotal']) ?? 0,
        health: HealthSnapshot.fromJson(j['health'] as Map<String, dynamic>),
      );

  final String childId;
  final DateTime from;
  final DateTime to;
  final DateTime today;
  final int? screenGoalMinutes;
  final int? studyGoalMinutes;
  final List<InsightDay> days;
  final List<HabitInsight> habits;
  final List<MedicationInsight> medications;
  final int starBalance;
  final double expensesTotal;
  final HealthSnapshot health;

  int sum(int Function(InsightDay d) f) => days.fold(0, (a, d) => a + f(d));
}

abstract interface class InsightsRepository {
  Future<ChildInsights> insights(String familyId, String childId, {required DateTime from, required DateTime to});
}

class ApiInsightsRepository implements InsightsRepository {
  ApiInsightsRepository(this._api);

  final ApiClient _api;

  @override
  Future<ChildInsights> insights(String familyId, String childId, {required DateTime from, required DateTime to}) async {
    try {
      final res = await _api.dio.get<Map<String, dynamic>>('/api/v1/families/$familyId/children/$childId/insights',
          queryParameters: {'from': insightsDay(from), 'to': insightsDay(to)});
      return ChildInsights.fromJson(res.data!);
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }
}

final insightsRepositoryProvider = Provider<InsightsRepository>((ref) => ApiInsightsRepository(ref.watch(apiClientProvider)));

/// (familyId, childId, from, to) — dates as yyyy-MM-dd so the key compares by value.
final childInsightsProvider = FutureProvider.autoDispose.family<ChildInsights, (String, String, String, String)>((ref, key) =>
    ref.watch(insightsRepositoryProvider).insights(key.$1, key.$2, from: DateTime.parse(key.$3), to: DateTime.parse(key.$4)));
