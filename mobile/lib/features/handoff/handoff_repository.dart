import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../insights/insights_repository.dart' show insightsDay;

int _i(Object? v) => (v as num?)?.toInt() ?? 0;
List<String> _s(Object? v) => [for (final x in v as List? ?? const []) x as String];

/// What was logged for the child on the day (times already family-local "HH:mm").
class HandoffSummary {
  const HandoffSummary({
    this.feeds = 0,
    this.bottleMl = 0,
    this.breastMinutes = 0,
    this.solids = 0,
    this.foods = const [],
    this.sleepMinutes = 0,
    this.sleeps = const [],
    this.doses = const [],
    this.screenMinutes = 0,
  });

  factory HandoffSummary.fromJson(Map<String, dynamic> j) => HandoffSummary(
        feeds: _i(j['feeds']),
        bottleMl: _i(j['bottleMl']),
        breastMinutes: _i(j['breastMinutes']),
        solids: _i(j['solids']),
        foods: _s(j['foods']),
        sleepMinutes: _i(j['sleepMinutes']),
        sleeps: _s(j['sleeps']),
        doses: _s(j['doses']),
        screenMinutes: _i(j['screenMinutes']),
      );

  final int feeds;
  final int bottleMl;
  final int breastMinutes;
  final int solids;
  final List<String> foods;
  final int sleepMinutes;
  final List<String> sleeps;
  final List<String> doses;
  final int screenMinutes;
}

/// The incidents a caregiver can tick. Sent to the server by name.
enum HandoffIncident { fall, fever, other }

HandoffIncident? _incident(String s) => switch (s) { 'Fall' => HandoffIncident.fall, 'Fever' => HandoffIncident.fever, 'Other' => HandoffIncident.other, _ => null };
String _incidentName(HandoffIncident i) => switch (i) { HandoffIncident.fall => 'Fall', HandoffIncident.fever => 'Fever', HandoffIncident.other => 'Other' };

class HandoffReport {
  const HandoffReport({
    required this.id,
    required this.childId,
    required this.childName,
    required this.byUserId,
    required this.byName,
    required this.day,
    required this.summary,
    this.incidents = const [],
    this.note,
    this.hasPhoto = false,
    required this.sentAt,
    this.thankedAt,
  });

  factory HandoffReport.fromJson(Map<String, dynamic> j) => HandoffReport(
        id: j['id'] as String,
        childId: j['childId'] as String,
        childName: j['childName'] as String,
        byUserId: j['byUserId'] as String,
        byName: j['byName'] as String,
        day: DateTime.parse(j['day'] as String),
        summary: HandoffSummary.fromJson(j['summary'] as Map<String, dynamic>),
        incidents: _s(j['incidents']).map(_incident).whereType<HandoffIncident>().toList(),
        note: j['note'] as String?,
        hasPhoto: j['hasPhoto'] as bool? ?? false,
        sentAt: DateTime.parse(j['sentAt'] as String).toLocal(),
        thankedAt: j['thankedAt'] == null ? null : DateTime.parse(j['thankedAt'] as String).toLocal(),
      );

  final String id;
  final String childId;
  final String childName;
  final String byUserId;
  final String byName;
  final DateTime day;
  final HandoffSummary summary;
  final List<HandoffIncident> incidents;
  final String? note;
  final bool hasPhoto;
  final DateTime sentAt;
  final DateTime? thankedAt;

  String get byFirstName => byName.trim().split(RegExp(r'\s+')).first;
}

class HandoffDraft {
  const HandoffDraft({required this.day, required this.summary, this.sent});

  factory HandoffDraft.fromJson(Map<String, dynamic> j) => HandoffDraft(
        day: DateTime.parse(j['day'] as String),
        summary: HandoffSummary.fromJson(j['summary'] as Map<String, dynamic>),
        sent: j['sent'] == null ? null : HandoffReport.fromJson(j['sent'] as Map<String, dynamic>),
      );

  final DateTime day;
  final HandoffSummary summary;

  /// Today's report if the caregiver already sent one.
  final HandoffReport? sent;
}

abstract interface class HandoffRepository {
  Future<HandoffDraft> draft(String familyId, String childId);
  Future<HandoffReport> send(String familyId, String childId, {required Set<HandoffIncident> incidents, String? note});
  Future<HandoffReport> addPhoto(String familyId, String reportId, List<int> bytes, String fileName, String contentType);
  Future<Uint8List> photo(String familyId, String reportId);

  /// Newest first. [day] limits to one day, [childId] to one child.
  Future<List<HandoffReport>> list(String familyId, {String? childId, DateTime? day});
  Future<HandoffReport> thanks(String familyId, String reportId);
}

class ApiHandoffRepository implements HandoffRepository {
  ApiHandoffRepository(this._api);

  final ApiClient _api;

  String _f(String familyId) => '/api/v1/families/$familyId';

  Future<T> _guard<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }

  @override
  Future<HandoffDraft> draft(String familyId, String childId) => _guard(() async =>
      HandoffDraft.fromJson((await _api.dio.get<Map<String, dynamic>>('${_f(familyId)}/children/$childId/handoff/draft')).data!));

  @override
  Future<HandoffReport> send(String familyId, String childId, {required Set<HandoffIncident> incidents, String? note}) => _guard(() async {
        final res = await _api.dio.post<Map<String, dynamic>>('${_f(familyId)}/children/$childId/handoffs',
            data: {'incidents': [for (final i in incidents) _incidentName(i)], 'note': note});
        return HandoffReport.fromJson(res.data!);
      });

  @override
  Future<HandoffReport> addPhoto(String familyId, String reportId, List<int> bytes, String fileName, String contentType) => _guard(() async {
        final res = await _api.dio.post<Map<String, dynamic>>('${_f(familyId)}/handoffs/$reportId/photo',
            data: FormData.fromMap({'file': MultipartFile.fromBytes(bytes, filename: fileName, contentType: DioMediaType.parse(contentType))}));
        return HandoffReport.fromJson(res.data!);
      });

  @override
  Future<Uint8List> photo(String familyId, String reportId) => _guard(() async {
        final res = await _api.dio.get<List<int>>('${_f(familyId)}/handoffs/$reportId/photo', options: Options(responseType: ResponseType.bytes));
        return Uint8List.fromList(res.data!);
      });

  @override
  Future<List<HandoffReport>> list(String familyId, {String? childId, DateTime? day}) => _guard(() async {
        final res = await _api.dio.get<List<dynamic>>('${_f(familyId)}/handoffs', queryParameters: {
          if (childId != null) 'childId': childId,
          if (day != null) 'day': insightsDay(day),
        });
        return [for (final r in res.data!) HandoffReport.fromJson(r as Map<String, dynamic>)];
      });

  @override
  Future<HandoffReport> thanks(String familyId, String reportId) =>
      _guard(() async => HandoffReport.fromJson((await _api.dio.post<Map<String, dynamic>>('${_f(familyId)}/handoffs/$reportId/thanks')).data!));
}

final handoffRepositoryProvider = Provider<HandoffRepository>((ref) => ApiHandoffRepository(ref.watch(apiClientProvider)));

/// (familyId, childId)
final handoffDraftProvider = FutureProvider.autoDispose.family<HandoffDraft, (String, String)>((ref, key) => ref.watch(handoffRepositoryProvider).draft(key.$1, key.$2));

/// Today's reports for the parents' Today screen (device date; the family is normally in the same time zone).
final todayHandoffsProvider = FutureProvider.autoDispose.family<List<HandoffReport>, String>((ref, familyId) {
  final now = DateTime.now();
  return ref.watch(handoffRepositoryProvider).list(familyId, day: DateTime(now.year, now.month, now.day));
});

/// (familyId, childId or '' for every child)
final handoffHistoryProvider = FutureProvider.autoDispose.family<List<HandoffReport>, (String, String)>(
    (ref, key) => ref.watch(handoffRepositoryProvider).list(key.$1, childId: key.$2.isEmpty ? null : key.$2));

/// (familyId, reportId)
final handoffPhotoProvider = FutureProvider.autoDispose.family<Uint8List, (String, String)>((ref, key) => ref.watch(handoffRepositoryProvider).photo(key.$1, key.$2));
