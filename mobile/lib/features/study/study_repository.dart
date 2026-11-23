import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../messages/chat_realtime.dart';

DateTime? _date(Object? v) => v is String ? DateTime.parse(v).toLocal() : null;

/// A child's homework and reading today. While [runningSince] is set the app counts on from [receivedAt].
class ChildStudyStatus {
  ChildStudyStatus({
    required this.childId,
    this.dailyGoalMinutes,
    this.todaySeconds = 0,
    this.homeworkSeconds = 0,
    this.readingSeconds = 0,
    this.runningKind,
    this.runningSince,
    this.runningUntil,
    this.startedByName,
    this.streak = 0,
    DateTime? receivedAt,
  }) : receivedAt = receivedAt ?? DateTime.now();

  factory ChildStudyStatus.fromJson(Map<String, dynamic> j) => ChildStudyStatus(
        childId: j['childId'] as String,
        dailyGoalMinutes: j['dailyGoalMinutes'] as int?,
        todaySeconds: j['todaySeconds'] as int? ?? 0,
        homeworkSeconds: j['homeworkSeconds'] as int? ?? 0,
        readingSeconds: j['readingSeconds'] as int? ?? 0,
        runningKind: j['runningKind'] as String?,
        runningSince: _date(j['runningSince']),
        runningUntil: _date(j['runningUntil']),
        startedByName: j['startedByName'] as String?,
        streak: j['streak'] as int? ?? 0,
      );

  final String childId;
  final int? dailyGoalMinutes;
  final int todaySeconds;
  final int homeworkSeconds;
  final int readingSeconds;

  /// "Homework" or "Reading" while a timer runs.
  final String? runningKind;
  final DateTime? runningSince;
  final DateTime? runningUntil;
  final String? startedByName;
  final int streak;
  final DateTime receivedAt;

  bool get isRunning => runningSince != null;

  /// Today's seconds as of [now], counting the running timer on locally but not past its cap.
  int secondsAt(DateTime now) {
    if (!isRunning) return todaySeconds;
    final until = runningUntil != null && now.isAfter(runningUntil!) ? runningUntil! : now;
    final extra = until.difference(receivedAt).inSeconds;
    return todaySeconds + (extra > 0 ? extra : 0);
  }

  /// Seconds of the running stretch alone.
  int runningSecondsAt(DateTime now) {
    final since = runningSince;
    if (since == null) return 0;
    final until = runningUntil != null && now.isAfter(runningUntil!) ? runningUntil! : now;
    final s = until.difference(since).inSeconds;
    return s > 0 ? s : 0;
  }

  bool goalMetAt(DateTime now) => dailyGoalMinutes != null && secondsAt(now) >= dailyGoalMinutes! * 60;
}

class StudyDay {
  const StudyDay({required this.date, this.homeworkSeconds = 0, this.readingSeconds = 0, this.goalMet = false});

  factory StudyDay.fromJson(Map<String, dynamic> j) => StudyDay(
        date: DateTime.parse(j['date'] as String),
        homeworkSeconds: j['homeworkSeconds'] as int,
        readingSeconds: j['readingSeconds'] as int,
        goalMet: j['goalMet'] as bool? ?? false,
      );

  final DateTime date;
  final int homeworkSeconds;
  final int readingSeconds;
  final bool goalMet;
}

class StudyEntry {
  const StudyEntry({required this.id, required this.kind, required this.startedAt, required this.endedAt, this.seconds = 0, this.note, this.byName});

  factory StudyEntry.fromJson(Map<String, dynamic> j) => StudyEntry(
        id: j['id'] as String,
        kind: j['kind'] as String,
        startedAt: _date(j['startedAt'])!,
        endedAt: _date(j['endedAt'])!,
        seconds: j['seconds'] as int? ?? 0,
        note: j['note'] as String?,
        byName: j['byName'] as String?,
      );

  final String id;
  final String kind;
  final DateTime startedAt;
  final DateTime endedAt;
  final int seconds;
  final String? note;
  final String? byName;
}

class StudyHistory {
  const StudyHistory({this.dailyGoalMinutes, required this.days, required this.entries});

  factory StudyHistory.fromJson(Map<String, dynamic> j) => StudyHistory(
        dailyGoalMinutes: j['dailyGoalMinutes'] as int?,
        days: [for (final d in j['days'] as List) StudyDay.fromJson(d as Map<String, dynamic>)],
        entries: [for (final e in j['entries'] as List) StudyEntry.fromJson(e as Map<String, dynamic>)],
      );

  final int? dailyGoalMinutes;
  final List<StudyDay> days;
  final List<StudyEntry> entries;
}

abstract interface class StudyRepository {
  Future<List<ChildStudyStatus>> today(String familyId);
  Future<StudyHistory> history(String familyId, String childId);
  Future<ChildStudyStatus> start(String familyId, String childId, String kind);
  Future<ChildStudyStatus> stop(String familyId, String childId, {String? note});
  Future<ChildStudyStatus> add(String familyId, String childId, {required String kind, required int minutes, String? note});
  Future<ChildStudyStatus> delete(String familyId, String childId, String entryId);
  Future<ChildStudyStatus> setGoal(String familyId, String childId, int? minutes);
}

class ApiStudyRepository implements StudyRepository {
  ApiStudyRepository(this._api);

  final ApiClient _api;

  Future<ChildStudyStatus> _status(Future<Map<String, dynamic>?> Function() fn) async {
    try {
      return ChildStudyStatus.fromJson((await fn())!);
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }

  String _child(String familyId, String childId) => '/api/v1/families/$familyId/children/$childId/study';

  @override
  Future<List<ChildStudyStatus>> today(String familyId) async {
    try {
      final res = await _api.dio.get<List<dynamic>>('/api/v1/families/$familyId/study');
      return [for (final s in res.data!) ChildStudyStatus.fromJson(s as Map<String, dynamic>)];
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }

  @override
  Future<StudyHistory> history(String familyId, String childId) async {
    try {
      final res = await _api.dio.get<Map<String, dynamic>>(_child(familyId, childId));
      return StudyHistory.fromJson(res.data!);
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }

  @override
  Future<ChildStudyStatus> start(String familyId, String childId, String kind) =>
      _status(() async => (await _api.dio.post<Map<String, dynamic>>('${_child(familyId, childId)}/start', data: {'kind': kind})).data);

  @override
  Future<ChildStudyStatus> stop(String familyId, String childId, {String? note}) =>
      _status(() async => (await _api.dio.post<Map<String, dynamic>>('${_child(familyId, childId)}/stop', data: {'note': note})).data);

  @override
  Future<ChildStudyStatus> add(String familyId, String childId, {required String kind, required int minutes, String? note}) => _status(() async =>
      (await _api.dio.post<Map<String, dynamic>>('${_child(familyId, childId)}/entries', data: {'kind': kind, 'minutes': minutes, 'note': note})).data);

  @override
  Future<ChildStudyStatus> delete(String familyId, String childId, String entryId) =>
      _status(() async => (await _api.dio.delete<Map<String, dynamic>>('${_child(familyId, childId)}/$entryId')).data);

  @override
  Future<ChildStudyStatus> setGoal(String familyId, String childId, int? minutes) =>
      _status(() async => (await _api.dio.put<Map<String, dynamic>>('${_child(familyId, childId)}/goal', data: {'dailyMinutes': minutes})).data);
}

final studyRepositoryProvider = Provider<StudyRepository>((ref) => ApiStudyRepository(ref.watch(apiClientProvider)));

/// Today per child id; follows the other parent's taps live, polls each minute without a live connection.
final studyStatusProvider = FutureProvider.autoDispose.family<Map<String, ChildStudyStatus>, String>((ref, familyId) async {
  final realtime = ref.watch(chatRealtimeProvider);
  final live = realtime.studyEvents.where((e) => e['familyId'] == familyId).listen((_) => ref.invalidateSelf());
  final poll = Timer.periodic(const Duration(minutes: 1), (_) {
    if (!realtime.isConnected) ref.invalidateSelf();
  });
  ref.onDispose(() {
    live.cancel();
    poll.cancel();
  });
  return {for (final s in await ref.watch(studyRepositoryProvider).today(familyId)) s.childId: s};
});

final studyHistoryProvider = FutureProvider.autoDispose.family<StudyHistory, (String, String)>((ref, key) async {
  final realtime = ref.watch(chatRealtimeProvider);
  final live = realtime.studyEvents.where((e) => e['childId'] == key.$2).listen((_) => ref.invalidateSelf());
  ref.onDispose(live.cancel);
  return ref.watch(studyRepositoryProvider).history(key.$1, key.$2);
});
