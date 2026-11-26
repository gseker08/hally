import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../messages/chat_realtime.dart';
import '../../core/locale/units.dart';

/// One child's screen time today as the server reported it at [receivedAt] (this phone's clock).
///
/// The server keeps the timer, so both parents see the same time. Between updates the app counts on locally:
/// [secondsAt] adds the time since [receivedAt] while the timer runs, never past [runningUntil] (a forgotten
/// timer stops counting after 8 hours).
class ChildScreenTime {
  const ChildScreenTime({
    required this.childId,
    required this.todaySeconds,
    required this.receivedAt,
    this.dailyGoalMinutes,
    this.runningSince,
    this.runningUntil,
    this.asOf,
    this.startedByUserId,
    this.startedByName,
  });

  factory ChildScreenTime.fromJson(Map<String, dynamic> j, {DateTime? receivedAt}) => ChildScreenTime(
        childId: j['childId'] as String,
        dailyGoalMinutes: j['dailyGoalMinutes'] as int?,
        todaySeconds: j['todaySeconds'] as int,
        runningSince: _date(j['runningSince']),
        runningUntil: _date(j['runningUntil']),
        asOf: _date(j['asOf']),
        startedByUserId: j['startedByUserId'] as String?,
        startedByName: j['startedByName'] as String?,
        receivedAt: receivedAt ?? DateTime.now(),
      );

  static DateTime? _date(Object? v) => v is String ? DateTime.parse(v) : null;

  final String childId;
  final int? dailyGoalMinutes;
  final int todaySeconds;
  final DateTime? runningSince;
  final DateTime? runningUntil;
  final DateTime? asOf;
  final String? startedByUserId;
  final String? startedByName;
  final DateTime receivedAt;

  bool get isRunning => runningSince != null;

  int secondsAt(DateTime now) {
    if (!isRunning) return todaySeconds;
    var extra = now.difference(receivedAt).inSeconds;
    // Server times are compared with server times only, so a phone clock that is off does not matter.
    if (runningUntil != null && asOf != null) {
      final left = runningUntil!.difference(asOf!).inSeconds;
      if (extra > left) extra = left;
    }
    return todaySeconds + (extra < 0 ? 0 : extra);
  }

  /// 0..1+ of the goal used; null without a goal.
  double? progressAt(DateTime now) => dailyGoalMinutes == null ? null : secondsAt(now) / (dailyGoalMinutes! * 60);
}

class ChildScreenWeek {
  const ChildScreenWeek({required this.childId, required this.dailySeconds, required this.totalSeconds, required this.averageSeconds, required this.daysOverGoal, this.dailyGoalMinutes});

  factory ChildScreenWeek.fromJson(Map<String, dynamic> j) => ChildScreenWeek(
        childId: j['childId'] as String,
        dailyGoalMinutes: j['dailyGoalMinutes'] as int?,
        dailySeconds: [for (final s in j['dailySeconds'] as List) s as int],
        totalSeconds: j['totalSeconds'] as int,
        averageSeconds: j['averageSeconds'] as int,
        daysOverGoal: j['daysOverGoal'] as int,
      );

  final String childId;
  final int? dailyGoalMinutes;

  /// Seven values, Monday first.
  final List<int> dailySeconds;
  final int totalSeconds;
  final int averageSeconds;
  final int daysOverGoal;
}

class ScreenTimeWeek {
  const ScreenTimeWeek({required this.start, required this.children});

  factory ScreenTimeWeek.fromJson(Map<String, dynamic> j) => ScreenTimeWeek(
        start: DateTime.parse(j['start'] as String),
        children: [for (final c in j['children'] as List) ChildScreenWeek.fromJson(c as Map<String, dynamic>)],
      );

  final DateTime start;
  final List<ChildScreenWeek> children;
}

abstract interface class ScreenTimeRepository {
  Future<List<ChildScreenTime>> today(String familyId);
  Future<ScreenTimeWeek> week(String familyId, {DateTime? start});
  Future<ChildScreenTime> start(String familyId, String childId);
  Future<ChildScreenTime> stop(String familyId, String childId);
  Future<ChildScreenTime> addMinutes(String familyId, String childId, int minutes);
  Future<ChildScreenTime> setGoal(String familyId, String childId, int? dailyMinutes);
}

class ApiScreenTimeRepository implements ScreenTimeRepository {
  ApiScreenTimeRepository(this._api);

  final ApiClient _api;

  Future<T> _call<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }

  String _child(String familyId, String childId, String action) => '/api/v1/families/$familyId/children/$childId/screen-time/$action';

  Future<ChildScreenTime> _post(String url, [Object? data]) => _call(() async {
        final res = await _api.dio.post<Map<String, dynamic>>(url, data: data);
        return ChildScreenTime.fromJson(res.data!);
      });

  @override
  Future<List<ChildScreenTime>> today(String familyId) => _call(() async {
        final res = await _api.dio.get<Map<String, dynamic>>('/api/v1/families/$familyId/screen-time');
        final now = DateTime.now();
        return [for (final c in res.data!['children'] as List) ChildScreenTime.fromJson(c as Map<String, dynamic>, receivedAt: now)];
      });

  @override
  Future<ScreenTimeWeek> week(String familyId, {DateTime? start}) => _call(() async {
        final res = await _api.dio.get<Map<String, dynamic>>('/api/v1/families/$familyId/screen-time/week',
            queryParameters: start == null ? null : {'start': '${start.year.toString().padLeft(4, '0')}-${start.month.toString().padLeft(2, '0')}-${start.day.toString().padLeft(2, '0')}'});
        return ScreenTimeWeek.fromJson(res.data!);
      });

  @override
  Future<ChildScreenTime> start(String familyId, String childId) => _post(_child(familyId, childId, 'start'));

  @override
  Future<ChildScreenTime> stop(String familyId, String childId) => _post(_child(familyId, childId, 'stop'));

  @override
  Future<ChildScreenTime> addMinutes(String familyId, String childId, int minutes) => _post(_child(familyId, childId, 'entries'), {'minutes': minutes});

  @override
  Future<ChildScreenTime> setGoal(String familyId, String childId, int? dailyMinutes) => _call(() async {
        final res = await _api.dio.put<Map<String, dynamic>>(_child(familyId, childId, 'goal'), data: {'dailyMinutes': dailyMinutes});
        return ChildScreenTime.fromJson(res.data!);
      });
}

final screenTimeRepositoryProvider = Provider<ScreenTimeRepository>((ref) => ApiScreenTimeRepository(ref.watch(apiClientProvider)));

/// Today's screen time per child id. Loads once, then follows live updates from the other parent's taps
/// (SignalR), and refreshes every minute when the live connection is down.
class ScreenTimeController extends AutoDisposeFamilyAsyncNotifier<Map<String, ChildScreenTime>, String> {
  StreamSubscription<Map<String, dynamic>>? _live;
  Timer? _poll;

  ScreenTimeRepository get _repo => ref.read(screenTimeRepositoryProvider);

  @override
  Future<Map<String, ChildScreenTime>> build(String familyId) async {
    final realtime = ref.watch(chatRealtimeProvider);
    _live = realtime.screenTimeEvents.listen((e) {
      if (e['familyId'] != familyId || e['status'] is! Map) return;
      _apply(ChildScreenTime.fromJson(Map<String, dynamic>.from(e['status'] as Map)));
    });
    _poll = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!realtime.isConnected) refresh();
    });
    ref.onDispose(() {
      _live?.cancel();
      _poll?.cancel();
    });
    return _load();
  }

  Future<Map<String, ChildScreenTime>> _load() async => {for (final c in await _repo.today(arg)) c.childId: c};

  Future<void> refresh() async {
    try {
      state = AsyncData(await _load());
    } catch (_) {
      // Keep what we show; the next tick tries again.
    }
  }

  void _apply(ChildScreenTime status) {
    final current = state.valueOrNull ?? const {};
    state = AsyncData({...current, status.childId: status});
  }

  Future<void> _run(Future<ChildScreenTime> Function() action) async => _apply(await action());

  Future<void> start(String childId) => _run(() => _repo.start(arg, childId));
  Future<void> stop(String childId) => _run(() => _repo.stop(arg, childId));
  Future<void> addMinutes(String childId, int minutes) => _run(() => _repo.addMinutes(arg, childId, minutes));
  Future<void> setGoal(String childId, int? minutes) => _run(() => _repo.setGoal(arg, childId, minutes));
}

final screenTimeProvider =
    AsyncNotifierProvider.autoDispose.family<ScreenTimeController, Map<String, ChildScreenTime>, String>(ScreenTimeController.new);

final screenTimeWeekProvider = FutureProvider.autoDispose.family<ScreenTimeWeek, String>((ref, familyId) => ref.watch(screenTimeRepositoryProvider).week(familyId));

/// "1 sa 05 dk" / "1 h 05 min"; under an hour "12 dk"; with [withSeconds] "12:07" style for a running clock.
String formatScreenDuration(int seconds, {required String lang, bool withSeconds = false}) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  if (withSeconds) {
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }
  final hu = durationUnits(lang).h;
  final mu = durationUnits(lang).min;
  if (h == 0) return '$m $mu';
  if (m == 0) return '$h $hu';
  return '$h $hu ${m.toString().padLeft(2, '0')} $mu';
}
