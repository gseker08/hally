import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../messages/chat_realtime.dart';

/// A ready-made request on the child's "Bir şey iste" page.
class AskPreset {
  const AskPreset({this.id, required this.emoji, required this.title, this.question, this.options = const [], this.screenMinutes});

  factory AskPreset.fromJson(Map<String, dynamic> j) => AskPreset(
        id: j['id'] as String?,
        emoji: j['emoji'] as String? ?? '💬',
        title: j['title'] as String,
        question: j['question'] as String?,
        options: [for (final o in (j['options'] as List? ?? const [])) o as String],
        screenMinutes: (j['screenMinutes'] as num?)?.toInt(),
      );

  /// Null for one the parent just added and has not saved yet.
  final String? id;
  final String emoji;
  final String title;

  /// A follow-up with quick answers, e.g. "Kimin evine?" → Zeynep, Can.
  final String? question;
  final List<String> options;

  /// A yes gives this many extra screen minutes (it really postpones the lock).
  final int? screenMinutes;

  AskPreset copyWith(
          {String? emoji, String? title, String? question, bool clearQuestion = false, List<String>? options, int? screenMinutes, bool clearMinutes = false}) =>
      AskPreset(
        id: id,
        emoji: emoji ?? this.emoji,
        title: title ?? this.title,
        question: clearQuestion ? null : question ?? this.question,
        options: options ?? this.options,
        screenMinutes: clearMinutes ? null : screenMinutes ?? this.screenMinutes,
      );

  Map<String, dynamic> toJson() => {'id': id, 'emoji': emoji, 'title': title, 'question': question, 'options': options, 'screenMinutes': screenMinutes};
}

enum AskStatus { pending, yes, no, expired }

/// One request a child made and its answer.
class ChildAskItem {
  const ChildAskItem({
    required this.id,
    required this.childId,
    required this.childName,
    required this.emoji,
    required this.title,
    this.detail,
    this.screenMinutes,
    required this.status,
    this.note,
    this.answeredByName,
    this.answeredAt,
    required this.createdAt,
  });

  factory ChildAskItem.fromJson(Map<String, dynamic> j) => ChildAskItem(
        id: j['id'] as String,
        childId: j['childId'] as String,
        childName: j['childName'] as String? ?? '',
        emoji: j['emoji'] as String? ?? '💬',
        title: j['title'] as String,
        detail: j['detail'] as String?,
        screenMinutes: (j['screenMinutes'] as num?)?.toInt(),
        status: switch (j['status']) {
          'Yes' => AskStatus.yes,
          'No' => AskStatus.no,
          'Expired' => AskStatus.expired,
          _ => AskStatus.pending,
        },
        note: j['note'] as String?,
        answeredByName: j['answeredByName'] as String?,
        answeredAt: j['answeredAt'] == null ? null : DateTime.parse(j['answeredAt'] as String).toLocal(),
        createdAt: DateTime.parse(j['createdAt'] as String).toLocal(),
      );

  final String id;
  final String childId;
  final String childName;
  final String emoji;
  final String title;

  /// The answer to the preset's follow-up ("Zeynep").
  final String? detail;
  final int? screenMinutes;
  final AskStatus status;
  final String? note;
  final String? answeredByName;
  final DateTime? answeredAt;
  final DateTime createdAt;

  bool get isPending => status == AskStatus.pending;

  /// "Arkadaşıma gidebilir miyim? · Zeynep".
  String get line => detail == null ? title : '$title · $detail';
}

/// The child's "Bir şey iste" page: the ready-made requests and today's requests with their answers.
class ChildAsks {
  const ChildAsks({this.presets = const [], this.asks = const []});

  factory ChildAsks.fromJson(Map<String, dynamic> j) => ChildAsks(
        presets: [for (final p in (j['presets'] as List? ?? const [])) AskPreset.fromJson(p as Map<String, dynamic>)],
        asks: [for (final a in (j['asks'] as List? ?? const [])) ChildAskItem.fromJson(a as Map<String, dynamic>)],
      );

  final List<AskPreset> presets;
  final List<ChildAskItem> asks;

  bool get anyPending => asks.any((a) => a.isPending);
}

/// The parents' side: answering and the ready-made list.
abstract interface class AsksRepository {
  Future<List<ChildAskItem>> list(String familyId);

  /// Throws [ApiException] 409 `ask.already_answered` when the other parent was faster (the message names them).
  Future<ChildAskItem> answer(String familyId, String askId, {required bool yes, String? note});
  Future<List<AskPreset>> presets(String familyId, String lang);
  Future<List<AskPreset>> savePresets(String familyId, List<AskPreset> presets);
}

class ApiAsksRepository implements AsksRepository {
  ApiAsksRepository(this._api);

  final ApiClient _api;

  Future<T> _call<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }

  @override
  Future<List<ChildAskItem>> list(String familyId) => _call(() async {
        final res = await _api.dio.get<List<dynamic>>('/api/v1/families/$familyId/asks');
        return [for (final a in res.data!) ChildAskItem.fromJson(a as Map<String, dynamic>)];
      });

  @override
  Future<ChildAskItem> answer(String familyId, String askId, {required bool yes, String? note}) => _call(() async {
        final res = await _api.dio.post<Map<String, dynamic>>('/api/v1/families/$familyId/asks/$askId/answer', data: {'yes': yes, 'note': note});
        return ChildAskItem.fromJson(res.data!);
      });

  @override
  Future<List<AskPreset>> presets(String familyId, String lang) => _call(() async {
        final res = await _api.dio.get<List<dynamic>>('/api/v1/families/$familyId/ask-presets', queryParameters: {'lang': lang});
        return [for (final p in res.data!) AskPreset.fromJson(p as Map<String, dynamic>)];
      });

  @override
  Future<List<AskPreset>> savePresets(String familyId, List<AskPreset> presets) => _call(() async {
        final res = await _api.dio.put<List<dynamic>>('/api/v1/families/$familyId/ask-presets', data: {
          'presets': [for (final p in presets) p.toJson()]
        });
        return [for (final p in res.data!) AskPreset.fromJson(p as Map<String, dynamic>)];
      });
}

final asksRepositoryProvider = Provider<AsksRepository>((ref) => ApiAsksRepository(ref.watch(apiClientProvider)));

/// Today's requests and anything still open. Refreshes when the app hears about a new one.
final familyAsksProvider = FutureProvider.autoDispose.family<List<ChildAskItem>, String>((ref, familyId) async {
  final live = ref.watch(chatRealtimeProvider).pointsEvents.where((e) => e['familyId'] == familyId).listen((_) => ref.invalidateSelf());
  ref.onDispose(live.cancel);
  return ref.watch(asksRepositoryProvider).list(familyId);
});
