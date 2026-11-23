import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../messages/chat_realtime.dart';

TimeOfDay? _time(Object? v) {
  if (v is! String) return null;
  final p = v.split(':');
  return TimeOfDay(hour: int.parse(p[0]), minute: int.parse(p[1]));
}

String? _timeJson(TimeOfDay? t) => t == null ? null : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:00';

String dutyDate(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class DutySlot {
  const DutySlot({required this.kind, this.assigned = false, this.assigneeUserId, this.assigneeName, this.time, this.isChange = false, this.doneAt, this.doneByName});

  factory DutySlot.fromJson(Map<String, dynamic> j) => DutySlot(
        kind: j['kind'] as String,
        assigned: j['assigned'] as bool? ?? false,
        assigneeUserId: j['assigneeUserId'] as String?,
        assigneeName: j['assigneeName'] as String?,
        time: _time(j['time']),
        isChange: j['isChange'] as bool? ?? false,
        doneAt: j['doneAt'] is String ? DateTime.parse(j['doneAt'] as String).toLocal() : null,
        doneByName: j['doneByName'] as String?,
      );

  /// "DropOff" or "PickUp".
  final String kind;
  final bool assigned;
  final String? assigneeUserId;
  final String? assigneeName;
  final TimeOfDay? time;
  final bool isChange;
  final DateTime? doneAt;
  final String? doneByName;
}

class DutyDay {
  const DutyDay({required this.date, required this.dropOff, required this.pickUp});

  factory DutyDay.fromJson(Map<String, dynamic> j) => DutyDay(
        date: DateTime.parse(j['date'] as String),
        dropOff: DutySlot.fromJson(j['dropOff'] as Map<String, dynamic>),
        pickUp: DutySlot.fromJson(j['pickUp'] as Map<String, dynamic>),
      );

  final DateTime date;
  final DutySlot dropOff;
  final DutySlot pickUp;

  DutySlot slot(String kind) => kind == 'DropOff' ? dropOff : pickUp;
}

class DutyAdult {
  const DutyAdult({required this.userId, required this.name});

  factory DutyAdult.fromJson(Map<String, dynamic> j) => DutyAdult(userId: j['userId'] as String, name: j['name'] as String);

  final String userId;
  final String name;
}

class DutyWeek {
  const DutyWeek({required this.start, required this.today, required this.days, this.adults = const []});

  factory DutyWeek.fromJson(Map<String, dynamic> j) => DutyWeek(
        start: DateTime.parse(j['start'] as String),
        today: DateTime.parse(j['today'] as String),
        days: [for (final d in j['days'] as List) DutyDay.fromJson(d as Map<String, dynamic>)],
        adults: [for (final a in j['adults'] as List? ?? const []) DutyAdult.fromJson(a as Map<String, dynamic>)],
      );

  final DateTime start;
  final DateTime today;
  final List<DutyDay> days;
  final List<DutyAdult> adults;

  DutyDay? get todayDay => days.where((d) => d.date == today).firstOrNull;
}

/// Who does a duty: an adult, a typed name, or nobody (both null).
class DutyAssignee {
  const DutyAssignee({this.userId, this.name, this.time});

  final String? userId;
  final String? name;
  final TimeOfDay? time;

  Map<String, dynamic> toJson() => {'assigneeUserId': userId, 'assigneeName': name, 'time': _timeJson(time)};
}

abstract interface class DutiesRepository {
  Future<DutyWeek> week(String familyId, {DateTime? start});
  Future<DutyWeek> setRule(String familyId, int weekday, String kind, DutyAssignee assignee);
  Future<DutyWeek> setDay(String familyId, DateTime date, String kind, DutyAssignee assignee);
  Future<DutyWeek> resetDay(String familyId, DateTime date, String kind);
  Future<DutyWeek> done(String familyId, String kind);
  Future<DutyWeek> undone(String familyId, String kind);
}

class ApiDutiesRepository implements DutiesRepository {
  ApiDutiesRepository(this._api);

  final ApiClient _api;

  Future<DutyWeek> _week(Future<dynamic> Function() fn) async {
    try {
      return DutyWeek.fromJson((await fn()).data as Map<String, dynamic>);
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }

  String _u(String familyId) => '/api/v1/families/$familyId/duties';

  @override
  Future<DutyWeek> week(String familyId, {DateTime? start}) =>
      _week(() => _api.dio.get<Map<String, dynamic>>(_u(familyId), queryParameters: {if (start != null) 'start': dutyDate(start)}));

  @override
  Future<DutyWeek> setRule(String familyId, int weekday, String kind, DutyAssignee assignee) =>
      _week(() => _api.dio.put<Map<String, dynamic>>('${_u(familyId)}/rules/$weekday/$kind', data: assignee.toJson()));

  @override
  Future<DutyWeek> setDay(String familyId, DateTime date, String kind, DutyAssignee assignee) =>
      _week(() => _api.dio.put<Map<String, dynamic>>('${_u(familyId)}/${dutyDate(date)}/$kind', data: assignee.toJson()));

  @override
  Future<DutyWeek> resetDay(String familyId, DateTime date, String kind) =>
      _week(() => _api.dio.delete<Map<String, dynamic>>('${_u(familyId)}/${dutyDate(date)}/$kind'));

  @override
  Future<DutyWeek> done(String familyId, String kind) => _week(() => _api.dio.post<Map<String, dynamic>>('${_u(familyId)}/today/$kind/done'));

  @override
  Future<DutyWeek> undone(String familyId, String kind) => _week(() => _api.dio.delete<Map<String, dynamic>>('${_u(familyId)}/today/$kind/done'));
}

final dutiesRepositoryProvider = Provider<DutiesRepository>((ref) => ApiDutiesRepository(ref.watch(apiClientProvider)));

/// One week of the school run; key is (familyId, week offset from this week). Follows the other parent live.
final dutyWeekProvider = FutureProvider.autoDispose.family<DutyWeek, (String, int)>((ref, key) async {
  final live = ref.watch(chatRealtimeProvider).dutiesEvents.where((e) => e['familyId'] == key.$1).listen((_) => ref.invalidateSelf());
  ref.onDispose(live.cancel);
  final repo = ref.watch(dutiesRepositoryProvider);
  if (key.$2 == 0) return repo.week(key.$1);
  final current = await repo.week(key.$1);
  return repo.week(key.$1, start: current.start.add(Duration(days: 7 * key.$2)));
});
