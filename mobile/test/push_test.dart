import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hally/core/api/api_client.dart';
import 'package:hally/core/auth/token_storage.dart';
import 'package:hally/features/notifications/push.dart';

class _Tokens implements TokenStorage {
  @override
  Future<StoredTokens?> read() async => const StoredTokens(accessToken: 'a', refreshToken: 'r');
  @override
  Future<void> write(StoredTokens t) async {}
  @override
  Future<void> clear() async {}
}

/// Records API calls and answers 204.
class _Api implements HttpClientAdapter {
  final calls = <String>[];

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? body, Future<void>? cancel) async {
    final data = o.data == null ? '' : ' ${jsonEncode(o.data)}';
    final query = o.queryParameters.isEmpty ? '' : '?${Uri(queryParameters: o.queryParameters.cast()).query}';
    calls.add('${o.method} ${o.path}$query$data');
    return ResponseBody.fromString('', 204);
  }

  @override
  void close({bool force = false}) {}
}

class _FakePush implements PushMessaging {
  _FakePush({this.available = true, this.allowed = true, this.initial});

  final bool available;
  final bool allowed;
  final PushEvent? initial;
  final refresh = StreamController<String>.broadcast();
  final taps = StreamController<PushEvent>.broadcast();
  final inApp = StreamController<PushEvent>.broadcast();

  @override
  Future<bool> init() async => available;
  @override
  Future<bool> requestPermission() async => allowed;
  @override
  Future<String?> token() async => 'tok1';
  @override
  Stream<String> get tokenRefresh => refresh.stream;
  @override
  Stream<PushEvent> get foreground => inApp.stream;
  @override
  Stream<PushEvent> get opened => taps.stream;
  @override
  Future<PushEvent?> initialOpened() async => initial;
  @override
  Future<void> deleteToken() async {}
}

void main() {
  late _Api api;
  late ApiClient client;
  late List<String> opened;
  late List<PushEvent> shown;

  setUp(() {
    api = _Api();
    client = ApiClient(_Tokens(), dio: Dio(BaseOptions(baseUrl: 'http://api.test'))..httpClientAdapter = api);
    opened = [];
    shown = [];
  });

  PushController controller(_FakePush push) => PushController(push, client, opened.add, onForeground: shown.add);

  group('pushRoute', () {
    test('a chat message opens that chat', () {
      expect(pushRoute({'kind': 'Message', 'chatKey': 'family', 'familyId': 'f1'}), '/chats/family');
      expect(pushRoute({'kind': 'Message', 'chatKey': 'u2'}), '/chats/u2');
    });

    test('reminders open tasks or the calendar', () {
      expect(pushRoute({'kind': 'Reminder', 'targetKind': 'Task', 'targetId': 't1'}), '/tasks');
      expect(pushRoute({'kind': 'Reminder', 'targetKind': 'Event', 'targetId': 'e1'}), '/calendar');
    });

    test('anything else opens the inbox', () {
      expect(pushRoute({'kind': 'EveningPrep'}), '/notifications');
      expect(pushRoute({'kind': 'Message'}), '/notifications');
      expect(pushRoute({}), '/notifications');
    });
  });

  test('registers the token, follows refreshes and unregisters on sign-out', () async {
    final push = _FakePush();
    final c = controller(push);
    await c.start();
    expect(api.calls, ['PUT /api/v1/me/devices {"platform":"android","token":"tok1"}']);
    expect(c.registeredToken, 'tok1');

    push.refresh.add('tok2');
    await pumpEventQueue();
    expect(api.calls.last, 'PUT /api/v1/me/devices {"platform":"android","token":"tok2"}');

    await c.unregister();
    expect(api.calls.last, 'DELETE /api/v1/me/devices?token=tok2');
    expect(c.registeredToken, isNull);
    c.dispose();
  });

  test('taps open the right screen, including the tap that started the app', () async {
    final push = _FakePush(initial: const PushEvent(data: {'kind': 'Message', 'chatKey': 'family'}));
    final c = controller(push);
    await c.start();
    expect(opened, ['/chats/family']);

    push.taps.add(const PushEvent(data: {'targetKind': 'Task'}));
    await pumpEventQueue();
    expect(opened, ['/chats/family', '/tasks']);

    push.inApp.add(const PushEvent(title: 'Hatırlatma', body: 'Veli toplantısı'));
    await pumpEventQueue();
    expect(shown.single.title, 'Hatırlatma');
    c.dispose();
  });

  test('nothing is registered when permission is refused or Firebase is not set up', () async {
    await controller(_FakePush(allowed: false)).start();
    await controller(_FakePush(available: false)).start();
    expect(api.calls, isEmpty);
  });

  test('push is off in widget tests', () async {
    expect(await NoPushMessaging().init(), isFalse);
  });
}
