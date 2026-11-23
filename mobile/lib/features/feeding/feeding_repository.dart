import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../messages/chat_realtime.dart';

class FeedingEntry {
  const FeedingEntry({required this.id, required this.childId, required this.kind, required this.at, this.side, this.minutes, this.amountMl, this.food, this.note, this.byName});

  factory FeedingEntry.fromJson(Map<String, dynamic> j) => FeedingEntry(
        id: j['id'] as String,
        childId: j['childId'] as String,
        kind: j['kind'] as String,
        at: DateTime.parse(j['at'] as String).toLocal(),
        side: j['side'] as String?,
        minutes: j['minutes'] as int?,
        amountMl: j['amountMl'] as int?,
        food: j['food'] as String?,
        note: j['note'] as String?,
        byName: j['byName'] as String?,
      );

  final String id;
  final String childId;

  /// "Breast", "Bottle" or "Solid".
  final String kind;
  final DateTime at;

  /// "Left", "Right" or "Both" for breast feeds.
  final String? side;
  final int? minutes;
  final int? amountMl;
  final String? food;
  final String? note;
  final String? byName;
}

class ChildFeedingStatus {
  const ChildFeedingStatus({required this.childId, this.last, this.nextSide, this.feedsToday = 0, this.bottleMlToday = 0});

  factory ChildFeedingStatus.fromJson(Map<String, dynamic> j) => ChildFeedingStatus(
        childId: j['childId'] as String,
        last: j['last'] is Map ? FeedingEntry.fromJson(Map<String, dynamic>.from(j['last'] as Map)) : null,
        nextSide: j['nextSide'] as String?,
        feedsToday: j['feedsToday'] as int? ?? 0,
        bottleMlToday: j['bottleMlToday'] as int? ?? 0,
      );

  final String childId;
  final FeedingEntry? last;
  final String? nextSide;
  final int feedsToday;
  final int bottleMlToday;
}

class FeedingDay {
  const FeedingDay({required this.date, this.feeds = 0, this.breastFeeds = 0, this.breastMinutes = 0, this.bottles = 0, this.bottleMl = 0, this.solids = 0});

  factory FeedingDay.fromJson(Map<String, dynamic> j) => FeedingDay(
        date: DateTime.parse(j['date'] as String),
        feeds: j['feeds'] as int,
        breastFeeds: j['breastFeeds'] as int,
        breastMinutes: j['breastMinutes'] as int,
        bottles: j['bottles'] as int,
        bottleMl: j['bottleMl'] as int,
        solids: j['solids'] as int,
      );

  final DateTime date;
  final int feeds;
  final int breastFeeds;
  final int breastMinutes;
  final int bottles;
  final int bottleMl;
  final int solids;
}

class FeedingHistory {
  const FeedingHistory({required this.days, required this.entries});

  factory FeedingHistory.fromJson(Map<String, dynamic> j) => FeedingHistory(
        days: [for (final d in j['days'] as List) FeedingDay.fromJson(d as Map<String, dynamic>)],
        entries: [for (final e in j['entries'] as List) FeedingEntry.fromJson(e as Map<String, dynamic>)],
      );

  final List<FeedingDay> days;
  final List<FeedingEntry> entries;
}

abstract interface class FeedingRepository {
  Future<List<ChildFeedingStatus>> status(String familyId);
  Future<FeedingHistory> history(String familyId, String childId);
  Future<ChildFeedingStatus> add(String familyId, String childId,
      {required String kind, DateTime? at, String? side, int? minutes, int? amountMl, String? food, String? note});
  Future<void> delete(String familyId, String childId, String entryId);
}

class ApiFeedingRepository implements FeedingRepository {
  ApiFeedingRepository(this._api);

  final ApiClient _api;

  Future<T> _call<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }

  String _child(String familyId, String childId) => '/api/v1/families/$familyId/children/$childId/feeding';

  @override
  Future<List<ChildFeedingStatus>> status(String familyId) => _call(() async {
        final res = await _api.dio.get<List<dynamic>>('/api/v1/families/$familyId/feeding');
        return [for (final s in res.data!) ChildFeedingStatus.fromJson(s as Map<String, dynamic>)];
      });

  @override
  Future<FeedingHistory> history(String familyId, String childId) => _call(() async {
        final res = await _api.dio.get<Map<String, dynamic>>(_child(familyId, childId), queryParameters: {'days': 3});
        return FeedingHistory.fromJson(res.data!);
      });

  @override
  Future<ChildFeedingStatus> add(String familyId, String childId,
          {required String kind, DateTime? at, String? side, int? minutes, int? amountMl, String? food, String? note}) =>
      _call(() async {
        final res = await _api.dio.post<Map<String, dynamic>>(_child(familyId, childId), data: {
          'kind': kind,
          'at': at?.toUtc().toIso8601String(),
          'side': side,
          'minutes': minutes,
          'amountMl': amountMl,
          'food': food,
          'note': note,
        });
        return ChildFeedingStatus.fromJson(res.data!);
      });

  @override
  Future<void> delete(String familyId, String childId, String entryId) => _call(() => _api.dio.delete<dynamic>('${_child(familyId, childId)}/$entryId'));
}

final feedingRepositoryProvider = Provider<FeedingRepository>((ref) => ApiFeedingRepository(ref.watch(apiClientProvider)));

/// Last feed per child id; follows the other parent's entries live, polls each minute without a live connection.
final feedingStatusProvider = FutureProvider.autoDispose.family<Map<String, ChildFeedingStatus>, String>((ref, familyId) async {
  final realtime = ref.watch(chatRealtimeProvider);
  final live = realtime.feedingEvents.where((e) => e['familyId'] == familyId).listen((_) => ref.invalidateSelf());
  final poll = Timer.periodic(const Duration(minutes: 1), (_) {
    if (!realtime.isConnected) ref.invalidateSelf();
  });
  ref.onDispose(() {
    live.cancel();
    poll.cancel();
  });
  return {for (final s in await ref.watch(feedingRepositoryProvider).status(familyId)) s.childId: s};
});

final feedingHistoryProvider = FutureProvider.autoDispose.family<FeedingHistory, (String, String)>((ref, key) async {
  final realtime = ref.watch(chatRealtimeProvider);
  final live = realtime.feedingEvents.where((e) => e['childId'] == key.$2).listen((_) => ref.invalidateSelf());
  ref.onDispose(live.cancel);
  return ref.watch(feedingRepositoryProvider).history(key.$1, key.$2);
});
