import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../messages/chat_realtime.dart';

DateTime? _date(Object? v) => v is String ? DateTime.parse(v).toLocal() : null;

class SleepEntry {
  const SleepEntry({required this.id, required this.childId, required this.kind, required this.startedAt, this.endedAt, this.minutes = 0, this.startedByName, this.endedByName, this.note});

  factory SleepEntry.fromJson(Map<String, dynamic> j) => SleepEntry(
        id: j['id'] as String,
        childId: j['childId'] as String,
        kind: j['kind'] as String,
        startedAt: _date(j['startedAt'])!,
        endedAt: _date(j['endedAt']),
        minutes: j['minutes'] as int? ?? 0,
        startedByName: j['startedByName'] as String?,
        endedByName: j['endedByName'] as String?,
        note: j['note'] as String?,
      );

  final String id;
  final String childId;

  /// "Night" or "Nap".
  final String kind;
  final DateTime startedAt;
  final DateTime? endedAt;
  final int minutes;
  final String? startedByName;
  final String? endedByName;
  final String? note;

  bool get isNight => kind == 'Night';
}

class ChildSleepStatus {
  const ChildSleepStatus({required this.childId, this.asleep, this.lastSleep});

  factory ChildSleepStatus.fromJson(Map<String, dynamic> j) => ChildSleepStatus(
        childId: j['childId'] as String,
        asleep: j['asleep'] is Map ? SleepEntry.fromJson(Map<String, dynamic>.from(j['asleep'] as Map)) : null,
        lastSleep: j['lastSleep'] is Map ? SleepEntry.fromJson(Map<String, dynamic>.from(j['lastSleep'] as Map)) : null,
      );

  final String childId;
  final SleepEntry? asleep;
  final SleepEntry? lastSleep;
}

class SleepDay {
  const SleepDay({required this.date, this.nightMinutes = 0, this.napMinutes = 0, this.naps = 0});

  factory SleepDay.fromJson(Map<String, dynamic> j) => SleepDay(
        date: DateTime.parse(j['date'] as String),
        nightMinutes: j['nightMinutes'] as int,
        napMinutes: j['napMinutes'] as int,
        naps: j['naps'] as int,
      );

  final DateTime date;
  final int nightMinutes;
  final int napMinutes;
  final int naps;
}

class SleepHistory {
  const SleepHistory({required this.days, required this.entries, this.averageNightMinutes = 0, this.averageNapMinutes = 0});

  factory SleepHistory.fromJson(Map<String, dynamic> j) => SleepHistory(
        days: [for (final d in j['days'] as List) SleepDay.fromJson(d as Map<String, dynamic>)],
        entries: [for (final e in j['entries'] as List) SleepEntry.fromJson(e as Map<String, dynamic>)],
        averageNightMinutes: j['averageNightMinutes'] as int? ?? 0,
        averageNapMinutes: j['averageNapMinutes'] as int? ?? 0,
      );

  final List<SleepDay> days;
  final List<SleepEntry> entries;
  final int averageNightMinutes;
  final int averageNapMinutes;
}

abstract interface class SleepRepository {
  Future<List<ChildSleepStatus>> status(String familyId);
  Future<SleepHistory> history(String familyId, String childId);
  Future<ChildSleepStatus> asleep(String familyId, String childId, {DateTime? at});
  Future<ChildSleepStatus> awake(String familyId, String childId, {DateTime? at});
  Future<void> add(String familyId, String childId, {required DateTime startedAt, required DateTime endedAt, String? kind});
  Future<void> delete(String familyId, String childId, String entryId);
}

class ApiSleepRepository implements SleepRepository {
  ApiSleepRepository(this._api);

  final ApiClient _api;

  Future<T> _call<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }

  String _child(String familyId, String childId) => '/api/v1/families/$familyId/children/$childId/sleep';

  @override
  Future<List<ChildSleepStatus>> status(String familyId) => _call(() async {
        final res = await _api.dio.get<List<dynamic>>('/api/v1/families/$familyId/sleep');
        return [for (final s in res.data!) ChildSleepStatus.fromJson(s as Map<String, dynamic>)];
      });

  @override
  Future<SleepHistory> history(String familyId, String childId) => _call(() async {
        final res = await _api.dio.get<Map<String, dynamic>>(_child(familyId, childId));
        return SleepHistory.fromJson(res.data!);
      });

  @override
  Future<ChildSleepStatus> asleep(String familyId, String childId, {DateTime? at}) => _call(() async {
        final res = await _api.dio.post<Map<String, dynamic>>('${_child(familyId, childId)}/start', data: {'at': at?.toUtc().toIso8601String()});
        return ChildSleepStatus.fromJson(res.data!);
      });

  @override
  Future<ChildSleepStatus> awake(String familyId, String childId, {DateTime? at}) => _call(() async {
        final res = await _api.dio.post<Map<String, dynamic>>('${_child(familyId, childId)}/stop', data: {'at': at?.toUtc().toIso8601String()});
        return ChildSleepStatus.fromJson(res.data!);
      });

  @override
  Future<void> add(String familyId, String childId, {required DateTime startedAt, required DateTime endedAt, String? kind}) =>
      _call(() => _api.dio.post<dynamic>('${_child(familyId, childId)}/entries',
          data: {'startedAt': startedAt.toUtc().toIso8601String(), 'endedAt': endedAt.toUtc().toIso8601String(), 'kind': kind}));

  @override
  Future<void> delete(String familyId, String childId, String entryId) =>
      _call(() => _api.dio.delete<dynamic>('${_child(familyId, childId)}/entries/$entryId'));
}

final sleepRepositoryProvider = Provider<SleepRepository>((ref) => ApiSleepRepository(ref.watch(apiClientProvider)));

/// Asleep/awake per child id; follows the other parent's taps live, polls each minute without a live connection.
final sleepStatusProvider = FutureProvider.autoDispose.family<Map<String, ChildSleepStatus>, String>((ref, familyId) async {
  final realtime = ref.watch(chatRealtimeProvider);
  final live = realtime.sleepEvents.where((e) => e['familyId'] == familyId).listen((_) => ref.invalidateSelf());
  final poll = Timer.periodic(const Duration(minutes: 1), (_) {
    if (!realtime.isConnected) ref.invalidateSelf();
  });
  ref.onDispose(() {
    live.cancel();
    poll.cancel();
  });
  return {for (final s in await ref.watch(sleepRepositoryProvider).status(familyId)) s.childId: s};
});

final sleepHistoryProvider = FutureProvider.autoDispose.family<SleepHistory, (String, String)>((ref, key) async {
  final realtime = ref.watch(chatRealtimeProvider);
  final live = realtime.sleepEvents.where((e) => e['childId'] == key.$2).listen((_) => ref.invalidateSelf());
  ref.onDispose(live.cancel);
  return ref.watch(sleepRepositoryProvider).history(key.$1, key.$2);
});
