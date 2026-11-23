import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:signalr_netcore/signalr_client.dart';

import '../../core/api/api_client.dart';
import '../../core/auth/auth_repository.dart';
import '../../core/auth/token_storage.dart';
import '../../core/config/app_config.dart';
import 'messages_repository.dart';

/// A new message as the server announces it to this user. [chatKey] is this user's key for the chat.
class ChatMessageEvent {
  const ChatMessageEvent({required this.familyId, required this.chatKey, required this.message});

  factory ChatMessageEvent.fromJson(Map<String, dynamic> j) => ChatMessageEvent(
        familyId: j['familyId'] as String,
        chatKey: j['chatKey'] as String,
        message: FamilyChatMessage.fromJson(j['message'] as Map<String, dynamic>),
      );

  final String familyId;
  final String chatKey;
  final FamilyChatMessage message;
}

/// Live chat events. Screens listen to [events]; while [isConnected] they can poll much less often.
abstract interface class ChatRealtime {
  Stream<ChatMessageEvent> get events;

  /// Raw `ScreenTimeChanged` payloads (`{familyId, status}`); the screen time feature parses them.
  Stream<Map<String, dynamic>> get screenTimeEvents;

  /// Raw `MedicationChanged` payloads (`{familyId, medicationId}`).
  Stream<Map<String, dynamic>> get medicationEvents;

  /// Raw `ShoppingChanged` payloads (`{familyId}`).
  Stream<Map<String, dynamic>> get shoppingEvents;

  /// Raw `SleepChanged` payloads (`{familyId, childId}`).
  Stream<Map<String, dynamic>> get sleepEvents;
  bool get isConnected;
  Future<void> dispose();
}

/// SignalR connection to the API's `/hubs/chat`. The server only pushes; sending stays on the REST API.
///
/// Like a .NET `HubConnection`: build once, register handlers with `on`, then `start`. Automatic reconnect covers
/// short drops (0, 2, 10, 30 s); after that we try again every [retryAfter] for as long as the user is signed in.
class SignalRChatRealtime implements ChatRealtime {
  SignalRChatRealtime(this._storage, this._api, {String? hubUrl, this.retryAfter = const Duration(seconds: 30)})
      : _hubUrl = hubUrl ?? '${AppConfig.apiBaseUrl}/hubs/chat' {
    _connection = HubConnectionBuilder()
        .withUrl(_hubUrl, options: HttpConnectionOptions(accessTokenFactory: _token, requestTimeout: 15000))
        .withAutomaticReconnect()
        .build();
    _connection.on('MessageReceived', (args) {
      final payload = args?.firstOrNull;
      if (payload is Map) _events.add(ChatMessageEvent.fromJson(Map<String, dynamic>.from(payload)));
    });
    _connection.on('ScreenTimeChanged', (args) {
      final payload = args?.firstOrNull;
      if (payload is Map) _screenTime.add(Map<String, dynamic>.from(payload));
    });
    _connection.on('MedicationChanged', (args) {
      final payload = args?.firstOrNull;
      if (payload is Map) _medication.add(Map<String, dynamic>.from(payload));
    });
    _connection.on('ShoppingChanged', (args) {
      final payload = args?.firstOrNull;
      if (payload is Map) _shopping.add(Map<String, dynamic>.from(payload));
    });
    _connection.on('SleepChanged', (args) {
      final payload = args?.firstOrNull;
      if (payload is Map) _sleep.add(Map<String, dynamic>.from(payload));
    });
    _connection.onclose(({error}) => _scheduleRetry());
    unawaited(_start());
  }

  final TokenStorage _storage;
  final ApiClient _api;
  final String _hubUrl;
  final Duration retryAfter;
  late final HubConnection _connection;
  final _events = StreamController<ChatMessageEvent>.broadcast();
  final _screenTime = StreamController<Map<String, dynamic>>.broadcast();
  final _medication = StreamController<Map<String, dynamic>>.broadcast();
  final _shopping = StreamController<Map<String, dynamic>>.broadcast();
  final _sleep = StreamController<Map<String, dynamic>>.broadcast();
  Timer? _retry;
  bool _disposed = false;

  @override
  Stream<ChatMessageEvent> get events => _events.stream;

  @override
  Stream<Map<String, dynamic>> get screenTimeEvents => _screenTime.stream;

  @override
  Stream<Map<String, dynamic>> get medicationEvents => _medication.stream;

  @override
  Stream<Map<String, dynamic>> get shoppingEvents => _shopping.stream;

  @override
  Stream<Map<String, dynamic>> get sleepEvents => _sleep.stream;

  @override
  bool get isConnected => _connection.state == HubConnectionState.Connected;

  Future<void> _start() async {
    if (_disposed || _connection.state != HubConnectionState.Disconnected) return;
    try {
      await _connection.start();
    } catch (e) {
      debugPrint('chat realtime: start failed ($e)');
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    if (_disposed) return;
    _retry?.cancel();
    _retry = Timer(retryAfter, _start);
  }

  /// The hub reads the token from the query string at connect time. A token that is about to expire would be
  /// refused, so let the API client refresh it first (any authenticated call does that on a 401).
  Future<String> _token() async {
    var tokens = await _storage.read();
    if (tokens != null && _expiresSoon(tokens.accessToken)) {
      try {
        await _api.dio.get<dynamic>('/api/v1/me');
      } catch (_) {
        // Still try with what we have; the retry timer covers a failure.
      }
      tokens = await _storage.read();
    }
    return tokens?.accessToken ?? '';
  }

  static bool _expiresSoon(String jwt) {
    try {
      final payload = jwt.split('.')[1];
      final claims = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(payload)))) as Map<String, dynamic>;
      final exp = DateTime.fromMillisecondsSinceEpoch((claims['exp'] as int) * 1000);
      return exp.isBefore(DateTime.now().add(const Duration(minutes: 1)));
    } catch (_) {
      return true;
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _retry?.cancel();
    await _connection.stop().catchError((_) {});
    await _events.close();
    await _screenTime.close();
    await _medication.close();
    await _shopping.close();
    await _sleep.close();
  }
}

/// Stays quiet: used before sign-in and in tests that do not care about live events.
class NoChatRealtime implements ChatRealtime {
  @override
  Stream<ChatMessageEvent> get events => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get screenTimeEvents => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get medicationEvents => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get shoppingEvents => const Stream.empty();

  @override
  Stream<Map<String, dynamic>> get sleepEvents => const Stream.empty();

  @override
  bool get isConnected => false;

  @override
  Future<void> dispose() async {}
}

/// One connection per signed-in user; a new sign-in rebuilds it and the old one is closed.
final chatRealtimeProvider = Provider<ChatRealtime>((ref) {
  // Only the user id matters: refreshing the profile must not reconnect.
  final userId = ref.watch(meProvider.select((me) => me.valueOrNull?.id));
  if (userId == null) return NoChatRealtime();
  final realtime = SignalRChatRealtime(ref.watch(tokenStorageProvider), ref.watch(apiClientProvider));
  ref.onDispose(realtime.dispose);
  return realtime;
});
