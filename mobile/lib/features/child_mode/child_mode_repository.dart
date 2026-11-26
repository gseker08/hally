import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import '../../core/api/api_client.dart';
import '../../core/auth/token_storage.dart';
import '../../core/config/app_config.dart';
import '../activities/activities.dart';
import '../allowance/allowance.dart';
import '../asks/asks.dart';
import '../bedtime/bedtime.dart';
import '../exams/exams.dart';
import '../goal/family_goal.dart';
import '../messages/chat_realtime.dart';
import 'child_lock.dart';

// ─── Child phone ──────────────────────────────────────────────────────────────

/// This phone belongs to a child: paired with a parent's code, no account. Kept in the keystore.
class ChildSession {
  const ChildSession({required this.token, required this.childId, required this.firstName, required this.familyId});

  factory ChildSession.fromJson(Map<String, dynamic> j) => ChildSession(
        token: j['token'] as String,
        childId: j['childId'] as String,
        firstName: j['firstName'] as String,
        familyId: j['familyId'] as String,
      );

  final String token;
  final String childId;
  final String firstName;
  final String familyId;

  Map<String, dynamic> toJson() => {'token': token, 'childId': childId, 'firstName': firstName, 'familyId': familyId};
}

abstract interface class ChildSessionStorage {
  Future<ChildSession?> read();
  Future<void> write(ChildSession session);
  Future<void> clear();
}

class SecureChildSessionStorage implements ChildSessionStorage {
  SecureChildSessionStorage([FlutterSecureStorage? storage]) : _storage = storage ?? hallySecureStorage;

  static const _key = 'hally.child_session';
  final FlutterSecureStorage _storage;

  @override
  Future<ChildSession?> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return null;
    try {
      return ChildSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(ChildSession session) => _storage.write(key: _key, value: jsonEncode(session.toJson()));

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

final childSessionStorageProvider = Provider<ChildSessionStorage>((ref) => SecureChildSessionStorage());

/// The paired child on this phone, or null on a parent's phone. Invalidate after pairing or unpairing.
final childSessionProvider = FutureProvider<ChildSession?>((ref) => ref.watch(childSessionStorageProvider).read());

class ChildItem {
  const ChildItem({required this.id, required this.kind, required this.title, required this.cherries, required this.state});

  factory ChildItem.fromJson(Map<String, dynamic> j) => ChildItem(
        id: j['id'] as String,
        kind: j['kind'] as String,
        title: j['title'] as String,
        cherries: j['cherries'] as int,
        state: j['state'] as String,
      );

  final String id;

  /// Chore or Habit.
  final String kind;
  final String title;
  final int cherries;

  /// Todo, Pending or Done.
  final String state;

  bool get isHabit => kind == 'Habit';
  bool get isPending => state == 'Pending';
  bool get isDone => state == 'Done';
}

class ChildReward {
  const ChildReward({required this.id, required this.title, required this.cost, this.screenMinutes});

  factory ChildReward.fromJson(Map<String, dynamic> j) =>
      ChildReward(id: j['id'] as String, title: j['title'] as String, cost: j['cost'] as int, screenMinutes: j['screenMinutes'] as int?);

  final String id;
  final String title;
  final int cost;
  final int? screenMinutes;
}

class ChildScreen {
  const ChildScreen({this.goalMinutes, this.bonusMinutes = 0, this.limitMinutes, this.usedSeconds = 0, this.locked = false, this.bedtime = false});

  factory ChildScreen.fromJson(Map<String, dynamic> j) => ChildScreen(
        goalMinutes: j['goalMinutes'] as int?,
        bonusMinutes: j['bonusMinutes'] as int? ?? 0,
        limitMinutes: j['limitMinutes'] as int?,
        usedSeconds: j['usedSeconds'] as int? ?? 0,
        locked: j['locked'] as bool? ?? false,
        bedtime: j['bedtime'] as bool? ?? false,
      );

  final int? goalMinutes;
  final int bonusMinutes;
  final int? limitMinutes;
  final int usedSeconds;
  final bool locked;

  /// Locked for the night after the bedtime routine (not because time ran out).
  final bool bedtime;

  /// Minutes left today; null without a limit.
  int? get minutesLeft => limitMinutes == null ? null : ((limitMinutes! * 60 - usedSeconds) / 60).ceil().clamp(0, 24 * 60);
}

class ChildHome {
  const ChildHome({
    required this.childId,
    required this.firstName,
    required this.color,
    required this.familyName,
    this.balance = 0,
    this.weekCherries = 0,
    this.streakDays = 0,
    this.nextBonusIn = 7,
    this.requireApproval = true,
    this.today = const [],
    this.rewards = const [],
    this.screen = const ChildScreen(),
    this.todayMood,
    this.bedtime,
    this.exams = const [],
  });

  factory ChildHome.fromJson(Map<String, dynamic> j) {
    final child = j['child'] as Map<String, dynamic>;
    return ChildHome(
      childId: child['id'] as String,
      firstName: child['firstName'] as String,
      color: child['color'] as String? ?? 'cherry',
      familyName: j['familyName'] as String? ?? '',
      balance: j['balance'] as int? ?? 0,
      weekCherries: j['weekCherries'] as int? ?? 0,
      streakDays: j['streakDays'] as int? ?? 0,
      nextBonusIn: j['nextBonusIn'] as int? ?? 7,
      requireApproval: j['requireApproval'] as bool? ?? true,
      today: [for (final i in j['today'] as List? ?? const []) ChildItem.fromJson(i as Map<String, dynamic>)],
      rewards: [for (final r in j['rewards'] as List? ?? const []) ChildReward.fromJson(r as Map<String, dynamic>)],
      screen: ChildScreen.fromJson(j['screen'] as Map<String, dynamic>? ?? const {}),
      todayMood: j['todayMood'] as String?,
      bedtime: j['bedtime'] == null ? null : ChildBedtime.fromJson(j['bedtime'] as Map<String, dynamic>),
      exams: [for (final e in j['exams'] as List? ?? const []) ChildExam.fromJson(e as Map<String, dynamic>)],
    );
  }

  final String childId;
  final String firstName;
  final String color;
  final String familyName;
  final int balance;
  final int weekCherries;
  final int streakDays;
  final int nextBonusIn;
  final bool requireApproval;
  final List<ChildItem> today;
  final List<ChildReward> rewards;
  final ChildScreen screen;

  /// Today's "Bugün nasılsın?" answer (Great, Good, Okay, Sad, Angry, Tired); null until the child answers.
  final String? todayMood;

  /// Tonight's bedtime routine; null without one.
  final ChildBedtime? bedtime;

  /// Exams in the next two weeks (Sınav takvimi), soonest first.
  final List<ChildExam> exams;

  /// The cheapest reward still out of reach (the "next reward" bar).
  ChildReward? get nextReward {
    final ahead = rewards.where((r) => r.cost > balance).toList()..sort((a, b) => a.cost.compareTo(b.cost));
    return ahead.isEmpty ? null : ahead.first;
  }

  /// The cheapest extra-screen-time reward the child can buy now.
  ChildReward? get affordableScreenReward {
    final list = rewards.where((r) => r.screenMinutes != null && r.cost <= balance).toList()..sort((a, b) => a.cost.compareTo(b.cost));
    return list.isEmpty ? null : list.first;
  }
}

/// What a child's phone calls. A 401 means a parent unpaired the phone.
abstract interface class ChildApi {
  Future<ChildSession> pair(String code, {String? deviceName});
  Future<ChildHome> home();
  Future<ChildHome> markDone(ChildItem item);
  Future<ChildHome> redeem(String rewardId);
  Future<ChildScreen> reportScreen(int usedSeconds);
  Future<void> requestTime(int minutes);

  /// "Bugün nasılsın?". Returns the cherries earned (1 the first time today, else 0).
  Future<int> answerMood(String mood, List<String> reasons);

  /// "Şimdi ne yapsam?": screen-free ideas by age and weather. [lang] is tr or en.
  Future<ChildActivities> activities(String lang);

  /// "Yaptım" for an idea; 422 activity.daily_limit after three a day.
  Future<ChildActivities> activityDone(String id, String lang);

  /// This week's family goal (the jar tab).
  Future<FamilyGoalState> goal();

  /// Checks bedtime step [index] (in order).
  Future<ChildBedtime> bedtimeDone(int index);

  /// "Bir şey iste": the ready-made requests and today's requests with their answers. [lang] is tr or en.
  Future<ChildAsks> asks(String lang);

  /// Sends a ready-made request ([presetId], with [detail] for its follow-up question) or the child's own [text].
  /// 422 `ask.already_pending` / `ask.too_many`.
  Future<ChildAsks> ask({String? presetId, String? text, String? detail, required String lang});

  /// Birikimim: balance, savings goal, rate and recent lines.
  Future<ChildSavings> savings();

  /// Sets the savings goal; null clears it.
  Future<ChildSavings> setSavingsGoal(SavingsGoal? goal);

  /// "Harçlığa çevir": asks a parent; 422 `allowance.pending`, `points.not_enough`, `allowance.cherries_invalid`.
  Future<ChildSavings> convert(int cherries);

  /// "Ebeveyn çıkışı": the parents' PIN takes this phone out of child mode (the server unpairs it and the session is
  /// dropped here). Throws [ChildExitException] for a wrong PIN, too many tries or no PIN set.
  Future<void> exit(String pin);

  /// "Çalıştım" for an upcoming exam (one cherry a day, with the parents' OK).
  Future<ChildHome> examStudied(String examId);
}

class UnpairedException implements Exception {}

/// Why "Ebeveyn çıkışı" did not work: `child.exit_pin_wrong` (with [triesLeft]), `child.exit_blocked` or `child.exit_no_pin`.
class ChildExitException implements Exception {
  const ChildExitException(this.code, {this.triesLeft});

  final String code;
  final int? triesLeft;

  bool get wrong => code == 'child.exit_pin_wrong';
  bool get blocked => code == 'child.exit_blocked';
  bool get noPin => code == 'child.exit_no_pin';
}

class DioChildApi implements ChildApi {
  DioChildApi(this._sessions, {Dio? dio}) : _dio = dio ?? Dio(BaseOptions(baseUrl: AppConfig.apiBaseUrl, connectTimeout: const Duration(seconds: 15))) {
    _dio.interceptors.add(QueuedInterceptorsWrapper(onRequest: (options, handler) async {
      final session = await _sessions.read();
      if (session != null) options.headers['X-Hally-Child'] = session.token;
      if (options.method == 'POST') options.headers.putIfAbsent('Idempotency-Key', () => const Uuid().v4());
      handler.next(options);
    }));
  }

  final ChildSessionStorage _sessions;
  final Dio _dio;

  Future<T> _call<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        await _sessions.clear();
        throw UnpairedException();
      }
      throw ApiClient.toApiException(e);
    }
  }

  Future<ChildHome> _home(Future<Response<Map<String, dynamic>>> request) async => ChildHome.fromJson((await request).data!);

  @override
  Future<ChildSession> pair(String code, {String? deviceName}) async {
    try {
      final res = await _dio.post<Map<String, dynamic>>('/api/v1/child/pair', data: {'code': code, 'deviceName': deviceName});
      final body = res.data!;
      final child = body['child'] as Map<String, dynamic>;
      final session = ChildSession(
        token: body['token'] as String,
        childId: child['id'] as String,
        firstName: child['firstName'] as String,
        familyId: body['familyId'] as String,
      );
      await _sessions.write(session);
      return session;
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }

  @override
  Future<ChildHome> home() => _call(() => _home(_dio.get<Map<String, dynamic>>('/api/v1/child/home')));

  @override
  Future<void> exit(String pin) async {
    try {
      await _dio.post<dynamic>('/api/v1/child/exit', data: {'pin': pin});
    } on DioException catch (e) {
      final data = e.response?.data;
      if (e.response?.statusCode == 422 && data is Map && (data['code'] as String? ?? '').startsWith('child.exit_')) {
        throw ChildExitException(data['code'] as String, triesLeft: data['triesLeft'] as int?);
      }
      if (e.response?.statusCode != 401) throw ApiClient.toApiException(e);
      // Already unpaired by a parent: the phone leaves child mode all the same.
    }
    await _sessions.clear();
  }

  @override
  Future<ChildHome> markDone(ChildItem item) =>
      _call(() => _home(_dio.post<Map<String, dynamic>>('/api/v1/child/${item.isHabit ? 'habits' : 'chores'}/${item.id}/done')));

  @override
  Future<ChildHome> examStudied(String examId) => _call(() async {
        await _dio.post<dynamic>('/api/v1/child/exams/$examId/studied');
        return _home(_dio.get<Map<String, dynamic>>('/api/v1/child/home'));
      });

  @override
  Future<ChildHome> redeem(String rewardId) => _call(() => _home(_dio.post<Map<String, dynamic>>('/api/v1/child/rewards/$rewardId/redeem')));

  @override
  Future<ChildScreen> reportScreen(int usedSeconds) => _call(() async {
        final res = await _dio.post<Map<String, dynamic>>('/api/v1/child/screen', data: {'usedSeconds': usedSeconds});
        return ChildScreen.fromJson(res.data!);
      });

  @override
  Future<void> requestTime(int minutes) => _call(() => _dio.post<dynamic>('/api/v1/child/screen/request', data: {'minutes': minutes}));

  @override
  Future<int> answerMood(String mood, List<String> reasons) => _call(() async {
        final res = await _dio.post<Map<String, dynamic>>('/api/v1/child/mood', data: {'mood': mood, 'reasons': reasons});
        return (res.data!['cherries'] as num?)?.toInt() ?? 0;
      });

  @override
  Future<ChildActivities> activities(String lang) =>
      _call(() async => ChildActivities.fromJson((await _dio.get<Map<String, dynamic>>('/api/v1/child/activities', queryParameters: {'lang': lang})).data!));

  @override
  Future<ChildActivities> activityDone(String id, String lang) => _call(() async =>
      ChildActivities.fromJson((await _dio.post<Map<String, dynamic>>('/api/v1/child/activities/$id/done', queryParameters: {'lang': lang})).data!));

  @override
  Future<FamilyGoalState> goal() => _call(() async => FamilyGoalState.fromJson((await _dio.get<Map<String, dynamic>>('/api/v1/child/goal')).data!));

  @override
  Future<ChildBedtime> bedtimeDone(int index) =>
      _call(() async => ChildBedtime.fromJson((await _dio.post<Map<String, dynamic>>('/api/v1/child/bedtime/steps/$index/done')).data!));

  @override
  Future<ChildSavings> savings() => _call(() async => ChildSavings.fromJson((await _dio.get<Map<String, dynamic>>('/api/v1/child/savings')).data!));

  @override
  Future<ChildSavings> setSavingsGoal(SavingsGoal? goal) => _call(() async => ChildSavings.fromJson((goal == null
          ? await _dio.delete<Map<String, dynamic>>('/api/v1/child/savings/goal')
          : await _dio.put<Map<String, dynamic>>('/api/v1/child/savings/goal', data: goal.toJson()))
      .data!));

  @override
  Future<ChildSavings> convert(int cherries) =>
      _call(() async => ChildSavings.fromJson((await _dio.post<Map<String, dynamic>>('/api/v1/child/savings/convert', data: {'cherries': cherries})).data!));

  @override
  Future<ChildAsks> asks(String lang) =>
      _call(() async => ChildAsks.fromJson((await _dio.get<Map<String, dynamic>>('/api/v1/child/asks', queryParameters: {'lang': lang})).data!));

  @override
  Future<ChildAsks> ask({String? presetId, String? text, String? detail, required String lang}) => _call(() async => ChildAsks.fromJson((await _dio
          .post<Map<String, dynamic>>('/api/v1/child/asks', queryParameters: {'lang': lang}, data: {'presetId': presetId, 'text': text, 'detail': detail}))
      .data!));
}

final childApiProvider = Provider<ChildApi>((ref) => DioChildApi(ref.watch(childSessionStorageProvider)));

/// The child's home; on an unpaired phone it drops the session so the app returns to the start.
/// The family goal on the child's phone; quietly nothing when it fails.
final kidGoalProvider = FutureProvider.autoDispose<FamilyGoalState>((ref) => ref.watch(childApiProvider).goal());

final childHomeProvider = FutureProvider.autoDispose<ChildHome>((ref) async {
  try {
    return await ref.watch(childApiProvider).home();
  } on UnpairedException {
    await ref.read(childLockProvider).stop();
    ref.invalidate(childSessionProvider);
    rethrow;
  }
});

// ─── Parent side ──────────────────────────────────────────────────────────────

class PairingCode {
  const PairingCode(this.code, this.expiresAt);

  final String code;
  final DateTime expiresAt;
}

class ChildDevice {
  const ChildDevice({required this.id, this.name, required this.pairedAt, required this.lastSeenAt});

  factory ChildDevice.fromJson(Map<String, dynamic> j) => ChildDevice(
        id: j['id'] as String,
        name: j['name'] as String?,
        pairedAt: DateTime.parse(j['pairedAt'] as String).toLocal(),
        lastSeenAt: DateTime.parse(j['lastSeenAt'] as String).toLocal(),
      );

  final String id;
  final String? name;
  final DateTime pairedAt;
  final DateTime lastSeenAt;
}

class ChildClaim {
  const ChildClaim(
      {required this.id, required this.childId, required this.childName, required this.kind, required this.title, required this.cherries, required this.at});

  factory ChildClaim.fromJson(Map<String, dynamic> j) => ChildClaim(
        id: j['id'] as String,
        childId: j['childId'] as String,
        childName: j['childName'] as String,
        kind: j['kind'] as String,
        title: j['title'] as String,
        cherries: j['cherries'] as int,
        at: DateTime.parse(j['at'] as String).toLocal(),
      );

  final String id;
  final String childId;
  final String childName;
  final String kind;
  final String title;
  final int cherries;
  final DateTime at;
}

abstract interface class ChildModeRepository {
  Future<PairingCode> pairingCode(String familyId, String childId);
  Future<List<ChildDevice>> devices(String familyId, String childId);
  Future<void> unpair(String familyId, String childId, String deviceId);
  Future<bool> requireApproval(String familyId);
  Future<bool> setRequireApproval(String familyId, bool value);

  /// Whether the parents set the PIN that takes a child's phone out of child mode.
  Future<bool> hasExitPin(String familyId);

  /// Sets the four-digit exit PIN (null removes it). It counts for every child phone in the family.
  Future<bool> setExitPin(String familyId, String? pin);
  Future<List<ChildClaim>> claims(String familyId);
  Future<List<ChildClaim>> decide(String familyId, String claimId, {required bool approve});
  Future<ChildScreen> deviceScreen(String familyId, String childId);
  Future<ChildScreen> grant(String familyId, String childId, int minutes);
}

class ApiChildModeRepository implements ChildModeRepository {
  ApiChildModeRepository(this._api);

  final ApiClient _api;

  Future<T> _call<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }

  String _f(String familyId) => '/api/v1/families/$familyId';

  List<ChildClaim> _claims(List<dynamic>? data) => [for (final c in data ?? const []) ChildClaim.fromJson(c as Map<String, dynamic>)];

  @override
  Future<PairingCode> pairingCode(String familyId, String childId) => _call(() async {
        final res = await _api.dio.post<Map<String, dynamic>>('${_f(familyId)}/children/$childId/pairing-code');
        return PairingCode(res.data!['code'] as String, DateTime.parse(res.data!['expiresAt'] as String).toLocal());
      });

  @override
  Future<List<ChildDevice>> devices(String familyId, String childId) => _call(() async {
        final res = await _api.dio.get<List<dynamic>>('${_f(familyId)}/children/$childId/devices');
        return [for (final d in res.data!) ChildDevice.fromJson(d as Map<String, dynamic>)];
      });

  @override
  Future<void> unpair(String familyId, String childId, String deviceId) =>
      _call(() => _api.dio.delete<dynamic>('${_f(familyId)}/children/$childId/devices/$deviceId'));

  @override
  Future<bool> requireApproval(String familyId) => _call(() async {
        final res = await _api.dio.get<Map<String, dynamic>>('${_f(familyId)}/child-mode');
        return res.data!['requireApproval'] as bool;
      });

  @override
  Future<bool> setRequireApproval(String familyId, bool value) => _call(() async {
        final res = await _api.dio.put<Map<String, dynamic>>('${_f(familyId)}/child-mode', data: {'requireApproval': value});
        return res.data!['requireApproval'] as bool;
      });

  @override
  Future<bool> hasExitPin(String familyId) => _call(() async {
        final res = await _api.dio.get<Map<String, dynamic>>('${_f(familyId)}/child-mode');
        return res.data!['hasExitPin'] as bool? ?? false;
      });

  @override
  Future<bool> setExitPin(String familyId, String? pin) => _call(() async {
        final res = await _api.dio.put<Map<String, dynamic>>('${_f(familyId)}/child-mode/exit-pin', data: {'pin': pin});
        return res.data!['hasExitPin'] as bool? ?? false;
      });

  @override
  Future<List<ChildClaim>> claims(String familyId) => _call(() async => _claims((await _api.dio.get<List<dynamic>>('${_f(familyId)}/claims')).data));

  @override
  Future<List<ChildClaim>> decide(String familyId, String claimId, {required bool approve}) =>
      _call(() async => _claims((await _api.dio.post<List<dynamic>>('${_f(familyId)}/claims/$claimId/${approve ? 'approve' : 'reject'}')).data));

  @override
  Future<ChildScreen> deviceScreen(String familyId, String childId) =>
      _call(() async => ChildScreen.fromJson((await _api.dio.get<Map<String, dynamic>>('${_f(familyId)}/children/$childId/device-screen')).data!));

  @override
  Future<ChildScreen> grant(String familyId, String childId, int minutes) => _call(() async =>
      ChildScreen.fromJson((await _api.dio.post<Map<String, dynamic>>('${_f(familyId)}/children/$childId/screen-bonus', data: {'minutes': minutes})).data!));
}

final childModeRepositoryProvider = Provider<ChildModeRepository>((ref) => ApiChildModeRepository(ref.watch(apiClientProvider)));

/// What the children marked done and waits for a parent; reloads when cherries change anywhere in the family.
final childClaimsProvider = FutureProvider.autoDispose.family<List<ChildClaim>, String>((ref, familyId) async {
  final live = ref.watch(chatRealtimeProvider).pointsEvents.where((e) => e['familyId'] == familyId).listen((_) => ref.invalidateSelf());
  ref.onDispose(live.cancel);
  return ref.watch(childModeRepositoryProvider).claims(familyId);
});

final childDevicesProvider =
    FutureProvider.autoDispose.family<List<ChildDevice>, (String, String)>((ref, key) => ref.watch(childModeRepositoryProvider).devices(key.$1, key.$2));

final childApprovalProvider =
    FutureProvider.autoDispose.family<bool, String>((ref, familyId) => ref.watch(childModeRepositoryProvider).requireApproval(familyId));

final childExitPinProvider = FutureProvider.autoDispose.family<bool, String>((ref, familyId) => ref.watch(childModeRepositoryProvider).hasExitPin(familyId));

final childDeviceScreenProvider =
    FutureProvider.autoDispose.family<ChildScreen, (String, String)>((ref, key) => ref.watch(childModeRepositoryProvider).deviceScreen(key.$1, key.$2));
