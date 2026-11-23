import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../capture/capture_models.dart';

class TaskItem {
  const TaskItem({
    required this.id,
    required this.title,
    this.notes,
    this.dueAt,
    required this.allDay,
    this.assigneeUserId,
    required this.state,
    this.childIds = const [],
  });

  factory TaskItem.fromJson(Map<String, dynamic> j) => TaskItem(
        id: j['id'] as String,
        title: j['title'] as String,
        notes: j['notes'] as String?,
        dueAt: j['dueAt'] == null ? null : DateTime.parse(j['dueAt'] as String).toLocal(),
        allDay: j['allDay'] as bool? ?? false,
        assigneeUserId: j['assigneeUserId'] as String?,
        state: j['state'] as String,
        childIds: _childIds(j),
      );

  final String id;
  final String title;
  final String? notes;
  final DateTime? dueAt;
  final bool allDay;
  final String? assigneeUserId;
  final String state;

  /// Children this task is about; empty means the whole family.
  final List<String> childIds;
}

List<String> _childIds(Map<String, dynamic> j) => [
      for (final id in j['childIds'] as List? ?? (j['childId'] == null ? const [] : [j['childId']])) id as String,
    ];

/// An event, or one occurrence of a repeating event (occurrences share the series [id]).
class EventItem {
  const EventItem({
    required this.id,
    required this.title,
    required this.startsAt,
    required this.allDay,
    this.repeat = EventRepeat.none,
    this.childIds = const [],
    this.endsAt,
    this.location,
    this.repeatUntil,
    DateTime? seriesStartsAt,
  }) : seriesStartsAt = seriesStartsAt ?? startsAt;

  factory EventItem.fromJson(Map<String, dynamic> j) {
    final startsAt = DateTime.parse(j['startsAt'] as String).toLocal();
    return EventItem(
      id: j['id'] as String,
      title: j['title'] as String,
      startsAt: startsAt,
      allDay: j['allDay'] as bool? ?? false,
      repeat: EventRepeat.fromApi(j['repeat'] as String?),
      childIds: _childIds(j),
      endsAt: j['endsAt'] == null ? null : DateTime.parse(j['endsAt'] as String).toLocal(),
      location: j['location'] as String?,
      repeatUntil: j['repeatUntil'] as String?,
      seriesStartsAt: j['seriesStartsAt'] == null ? startsAt : DateTime.parse(j['seriesStartsAt'] as String).toLocal(),
    );
  }

  final String id;
  final String title;

  /// This occurrence's start; for a series see [seriesStartsAt].
  final DateTime startsAt;
  final bool allDay;
  final EventRepeat repeat;

  /// Kept so an edit from the app does not wipe them (the app does not edit them yet).
  final DateTime? endsAt;
  final String? location;

  /// Last day of a series as `yyyy-MM-dd`, or null for no end.
  final String? repeatUntil;

  /// First occurrence of the series; equals [startsAt] for a one-off event.
  final DateTime seriesStartsAt;

  /// Children this event is about; empty means the whole family.
  final List<String> childIds;
}

enum EventRepeat {
  none('None'),
  daily('Daily'),
  weekly('Weekly'),
  monthly('Monthly');

  const EventRepeat(this.api);

  final String api;

  static EventRepeat fromApi(String? value) => values.firstWhere((r) => r.api == value, orElse: () => none);
}

class TodayData {
  const TodayData({required this.overdue, required this.dueToday, required this.events, required this.waiting});

  factory TodayData.fromJson(Map<String, dynamic> j) => TodayData(
        overdue: [for (final t in j['overdue'] as List) TaskItem.fromJson(t as Map<String, dynamic>)],
        dueToday: [for (final t in j['dueToday'] as List) TaskItem.fromJson(t as Map<String, dynamic>)],
        events: [for (final e in j['events'] as List) EventItem.fromJson(e as Map<String, dynamic>)],
        waiting: [for (final p in j['waitingForYou'] as List) Proposal.fromJson(p as Map<String, dynamic>)],
      );

  final List<TaskItem> overdue;
  final List<TaskItem> dueToday;
  final List<EventItem> events;
  final List<Proposal> waiting;

  bool get isEmpty => overdue.isEmpty && dueToday.isEmpty && events.isEmpty && waiting.isEmpty;
}

class SavedEvent {
  const SavedEvent({required this.event, required this.conflicts});

  final EventItem event;
  final List<EventItem> conflicts;
}

abstract interface class PlanningRepository {
  Future<TodayData> today(String familyId);
  Future<void> completeTask(String familyId, String taskId);
  Future<void> reopenTask(String familyId, String taskId);
  Future<List<TaskItem>> tasks(String familyId, {required String state});
  Future<TaskItem> createTask(String familyId, {required String title, DateTime? dueDate, List<String> childIds = const []});

  /// Saves edits to an open or done task. Every field is sent, so pass the unchanged ones through.
  Future<TaskItem> updateTask(String familyId, String taskId,
      {required String title, String? notes, DateTime? dueAt, required bool allDay, String? assigneeUserId, List<String> childIds = const []});

  /// Removes a task from the lists; [reopenTask] brings it back.
  Future<void> cancelTask(String familyId, String taskId);
  Future<List<EventItem>> events(String familyId, DateTime from, DateTime to);
  Future<SavedEvent> createEvent(String familyId,
      {required String title, required DateTime startsAt, required bool allDay, EventRepeat repeat = EventRepeat.none, List<String> childIds = const []});

  /// Replaces the event (the whole series for a repeating one). [startsAt] is the series' first occurrence.
  Future<SavedEvent> updateEvent(String familyId, EventItem original,
      {required String title, required DateTime startsAt, required bool allDay, required EventRepeat repeat, required List<String> childIds});

  /// Deletes the event; for a repeating event, the whole series.
  Future<void> deleteEvent(String familyId, String eventId);
}

class ApiPlanningRepository implements PlanningRepository {
  ApiPlanningRepository(this._api);

  final ApiClient _api;

  Future<T> _guard<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }

  @override
  Future<TodayData> today(String familyId) async {
    try {
      final res = await _api.dio.get<Map<String, dynamic>>('/api/v1/families/$familyId/today');
      return TodayData.fromJson(res.data!);
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }

  @override
  Future<void> completeTask(String familyId, String taskId) =>
      _guard(() => _api.dio.post<dynamic>('/api/v1/families/$familyId/tasks/$taskId/complete'));

  @override
  Future<void> reopenTask(String familyId, String taskId) =>
      _guard(() => _api.dio.post<dynamic>('/api/v1/families/$familyId/tasks/$taskId/reopen'));

  @override
  Future<List<TaskItem>> tasks(String familyId, {required String state}) => _guard(() async {
        final res = await _api.dio.get<List<dynamic>>('/api/v1/families/$familyId/tasks', queryParameters: {'state': state});
        return [for (final t in res.data!) TaskItem.fromJson(t as Map<String, dynamic>)];
      });

  @override
  Future<TaskItem> createTask(String familyId, {required String title, DateTime? dueDate, List<String> childIds = const []}) =>
      _guard(() async {
        final res = await _api.dio.post<Map<String, dynamic>>('/api/v1/families/$familyId/tasks', data: {
          'title': title,
          'dueAt': dueDate == null ? null : DateTime(dueDate.year, dueDate.month, dueDate.day).toUtc().toIso8601String(),
          'allDay': dueDate != null,
          'childIds': childIds,
        });
        return TaskItem.fromJson(res.data!);
      });

  @override
  Future<TaskItem> updateTask(String familyId, String taskId,
          {required String title, String? notes, DateTime? dueAt, required bool allDay, String? assigneeUserId, List<String> childIds = const []}) =>
      _guard(() async {
        final res = await _api.dio.put<Map<String, dynamic>>('/api/v1/families/$familyId/tasks/$taskId', data: {
          'title': title,
          'notes': notes,
          'dueAt': dueAt?.toUtc().toIso8601String(),
          'allDay': dueAt != null && allDay,
          'assigneeUserId': assigneeUserId,
          'childIds': childIds,
        });
        return TaskItem.fromJson(res.data!);
      });

  @override
  Future<void> cancelTask(String familyId, String taskId) =>
      _guard(() => _api.dio.post<dynamic>('/api/v1/families/$familyId/tasks/$taskId/cancel'));

  @override
  Future<List<EventItem>> events(String familyId, DateTime from, DateTime to) => _guard(() async {
        final res = await _api.dio.get<List<dynamic>>('/api/v1/families/$familyId/events', queryParameters: {
          'from': from.toUtc().toIso8601String(),
          'to': to.toUtc().toIso8601String(),
        });
        return [for (final e in res.data!) EventItem.fromJson(e as Map<String, dynamic>)];
      });

  @override
  Future<SavedEvent> createEvent(String familyId,
          {required String title, required DateTime startsAt, required bool allDay, EventRepeat repeat = EventRepeat.none, List<String> childIds = const []}) =>
      _guard(() async {
        final res = await _api.dio.post<Map<String, dynamic>>('/api/v1/families/$familyId/events', data: {
          'title': title,
          'startsAt': startsAt.toUtc().toIso8601String(),
          'allDay': allDay,
          'repeat': repeat.api,
          'childIds': childIds,
        });
        return _saved(res.data!);
      });

  @override
  Future<SavedEvent> updateEvent(String familyId, EventItem original,
          {required String title, required DateTime startsAt, required bool allDay, required EventRepeat repeat, required List<String> childIds}) =>
      _guard(() async {
        // Keep the end time's length when the start moves, and fields the app does not edit yet.
        final endsAt = original.endsAt?.add(startsAt.difference(original.seriesStartsAt));
        final res = await _api.dio.put<Map<String, dynamic>>('/api/v1/families/$familyId/events/${original.id}', data: {
          'title': title,
          'startsAt': startsAt.toUtc().toIso8601String(),
          'endsAt': endsAt?.toUtc().toIso8601String(),
          'allDay': allDay,
          'location': original.location,
          'repeat': repeat.api,
          'repeatUntil': repeat == EventRepeat.none ? null : original.repeatUntil,
          'childIds': childIds,
        });
        return _saved(res.data!);
      });

  @override
  Future<void> deleteEvent(String familyId, String eventId) =>
      _guard(() => _api.dio.delete<dynamic>('/api/v1/families/$familyId/events/$eventId'));

  static SavedEvent _saved(Map<String, dynamic> d) => SavedEvent(
        event: EventItem.fromJson(d['event'] as Map<String, dynamic>),
        conflicts: [for (final c in d['conflicts'] as List) EventItem.fromJson(c as Map<String, dynamic>)],
      );
}

final planningRepositoryProvider = Provider<PlanningRepository>((ref) => ApiPlanningRepository(ref.watch(apiClientProvider)));

final todayProvider = FutureProvider.autoDispose.family<TodayData, String>((ref, familyId) => ref.watch(planningRepositoryProvider).today(familyId));

/// A [days]-long calendar window starting at local midnight of [from] (a week or a 6-week month grid).
class CalendarRange {
  const CalendarRange(this.familyId, this.from, this.days);

  /// The Monday-based week containing [day].
  factory CalendarRange.week(String familyId, DateTime day) => CalendarRange(familyId, mondayOf(day), 7);

  /// The 6×7 month grid for [day]'s month, starting on the Monday on or before the 1st.
  factory CalendarRange.month(String familyId, DateTime day) => CalendarRange(familyId, mondayOf(DateTime(day.year, day.month)), 42);

  final String familyId;
  final DateTime from;
  final int days;

  // Calendar arithmetic (not Duration) so DST days still start at midnight.
  DateTime get to => DateTime(from.year, from.month, from.day + days);

  List<DateTime> get dates => [for (var i = 0; i < days; i++) DateTime(from.year, from.month, from.day + i)];

  @override
  bool operator ==(Object other) => other is CalendarRange && other.familyId == familyId && other.from == from && other.days == days;

  @override
  int get hashCode => Object.hash(familyId, from, days);
}

DateTime mondayOf(DateTime day) => DateTime(day.year, day.month, day.day - (day.weekday - DateTime.monday));

final calendarEventsProvider = FutureProvider.autoDispose.family<List<EventItem>, CalendarRange>(
    (ref, range) => ref.watch(planningRepositoryProvider).events(range.familyId, range.from, range.to));

final tasksProvider = FutureProvider.autoDispose.family<List<TaskItem>, (String, String)>(
    (ref, args) => ref.watch(planningRepositoryProvider).tasks(args.$1, state: args.$2));
