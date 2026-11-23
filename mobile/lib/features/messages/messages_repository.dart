import 'dart:collection';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';

/// The family chat's key; a direct chat's key is the other adult's user id.
const familyChatKey = 'family';

class FamilyChatMessage {
  const FamilyChatMessage({
    required this.id,
    required this.senderUserId,
    this.senderName,
    required this.body,
    required this.createdAt,
    this.taskId,
    this.eventId,
    this.linkTitle,
    this.hasPhoto = false,
  });

  factory FamilyChatMessage.fromJson(Map<String, dynamic> j) => FamilyChatMessage(
        id: j['id'] as String,
        senderUserId: j['senderUserId'] as String,
        senderName: j['senderName'] as String?,
        body: j['body'] as String,
        createdAt: DateTime.parse(j['createdAt'] as String),
        taskId: j['taskId'] as String?,
        eventId: j['eventId'] as String?,
        linkTitle: j['linkTitle'] as String?,
        hasPhoto: j['hasPhoto'] as bool? ?? false,
      );

  final String id;
  final String senderUserId;

  /// Null when the sender has left the family.
  final String? senderName;
  final String body;

  /// As sent by the server (UTC). Kept unconverted so it can be passed back as the polling cursor.
  final DateTime createdAt;
  final String? taskId;
  final String? eventId;
  final String? linkTitle;

  /// The message carries a photo; [body] is then its caption and may be empty.
  final bool hasPhoto;
}

class ChatSummary {
  const ChatSummary({required this.key, required this.isFamily, this.otherUserId, this.otherName, this.lastMessage, required this.unread});

  factory ChatSummary.fromJson(Map<String, dynamic> j) => ChatSummary(
        key: j['key'] as String,
        isFamily: j['kind'] == 'Family',
        otherUserId: j['otherUserId'] as String?,
        otherName: j['otherName'] as String?,
        lastMessage: j['lastMessage'] == null ? null : FamilyChatMessage.fromJson(j['lastMessage'] as Map<String, dynamic>),
        unread: j['unread'] as int? ?? 0,
      );

  final String key;
  final bool isFamily;
  final String? otherUserId;
  final String? otherName;
  final FamilyChatMessage? lastMessage;
  final int unread;
}

class ChatList {
  const ChatList({required this.chats, required this.totalUnread});

  final List<ChatSummary> chats;
  final int totalUnread;
}

abstract interface class MessagesRepository {
  Future<ChatList> chats(String familyId);

  /// The latest page, or the messages after [after] (polling), or before [before] (history). Oldest first.
  Future<List<FamilyChatMessage>> messages(String familyId, String key, {DateTime? after, DateTime? before});
  Future<FamilyChatMessage> send(String familyId, String key, String body, {String? taskId, String? eventId});
  Future<void> markRead(String familyId, String key);

  /// Sends a photo (JPEG, PNG, WebP or HEIC, up to 10 MB) with an optional caption.
  Future<FamilyChatMessage> sendPhoto(String familyId, String key, List<int> bytes, String fileName, String contentType, {String? caption});

  /// The photo of a message. Photos never change, so implementations may cache them.
  Future<Uint8List> photo(String familyId, String key, String messageId);
}

class ApiMessagesRepository implements MessagesRepository {
  ApiMessagesRepository(this._api);

  final ApiClient _api;

  Future<T> _guard<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } catch (e) {
      throw ApiClient.toApiException(e);
    }
  }

  String _base(String familyId) => '/api/v1/families/$familyId/chats';

  @override
  Future<ChatList> chats(String familyId) => _guard(() async {
        final res = await _api.dio.get<Map<String, dynamic>>(_base(familyId));
        final d = res.data!;
        return ChatList(
          chats: [for (final c in d['chats'] as List) ChatSummary.fromJson(c as Map<String, dynamic>)],
          totalUnread: d['totalUnread'] as int? ?? 0,
        );
      });

  @override
  Future<List<FamilyChatMessage>> messages(String familyId, String key, {DateTime? after, DateTime? before}) => _guard(() async {
        final res = await _api.dio.get<List<dynamic>>('${_base(familyId)}/$key/messages', queryParameters: {
          if (after != null) 'after': after.toUtc().toIso8601String(),
          if (before != null) 'before': before.toUtc().toIso8601String(),
        });
        return [for (final m in res.data!) FamilyChatMessage.fromJson(m as Map<String, dynamic>)];
      });

  @override
  Future<FamilyChatMessage> send(String familyId, String key, String body, {String? taskId, String? eventId}) => _guard(() async {
        final res = await _api.dio.post<Map<String, dynamic>>('${_base(familyId)}/$key/messages',
            data: {'body': body, 'taskId': taskId, 'eventId': eventId});
        return FamilyChatMessage.fromJson(res.data!);
      });

  @override
  Future<void> markRead(String familyId, String key) => _guard(() => _api.dio.post<dynamic>('${_base(familyId)}/$key/read'));

  @override
  Future<FamilyChatMessage> sendPhoto(String familyId, String key, List<int> bytes, String fileName, String contentType, {String? caption}) =>
      _guard(() async {
        final res = await _api.dio.post<Map<String, dynamic>>('${_base(familyId)}/$key/photos',
            data: FormData.fromMap({
              'file': MultipartFile.fromBytes(bytes, filename: fileName, contentType: DioMediaType.parse(contentType)),
              if (caption != null && caption.trim().isNotEmpty) 'caption': caption.trim(),
            }));
        return FamilyChatMessage.fromJson(res.data!);
      });

  /// Recently viewed photos, so scrolling back and forth does not download them again.
  final _photos = LinkedHashMap<String, Future<Uint8List>>();
  static const _cacheSize = 40;

  @override
  Future<Uint8List> photo(String familyId, String key, String messageId) {
    final cached = _photos.remove(messageId);
    if (cached != null) return _photos[messageId] = cached;
    final future = _guard(() async {
      final res = await _api.dio.get<List<int>>('${_base(familyId)}/$key/messages/$messageId/photo',
          options: Options(responseType: ResponseType.bytes));
      return Uint8List.fromList(res.data!);
    });
    _photos[messageId] = future;
    // A failed download is not kept, so the next try fetches again.
    future.catchError((Object _) {
      _photos.remove(messageId);
      return Uint8List(0);
    });
    while (_photos.length > _cacheSize) {
      _photos.remove(_photos.keys.first);
    }
    return future;
  }
}

final messagesRepositoryProvider = Provider<MessagesRepository>((ref) => ApiMessagesRepository(ref.watch(apiClientProvider)));

final chatListProvider = FutureProvider.autoDispose.family<ChatList, String>((ref, familyId) => ref.watch(messagesRepositoryProvider).chats(familyId));
