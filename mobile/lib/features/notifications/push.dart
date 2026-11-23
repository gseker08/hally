import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/auth/auth_repository.dart';
import '../../router.dart';
import '../messages/messages_repository.dart';
import '../../l10n/gen/app_localizations.dart';
import 'notifications_repository.dart';

/// A push as the app sees it: the title and body FCM shows, and the `data` map the server attaches.
class PushEvent {
  const PushEvent({this.title, this.body, this.data = const {}});

  final String? title;
  final String? body;
  final Map<String, dynamic> data;
}

/// Where tapping a push should take the user. Pure so it can be unit tested.
///
/// The server sends `kind=Message` + `chatKey` for chat messages, and `targetKind` (Task/Event) for reminders and
/// the evening summary, `kind=ScreenTimeGoal` when a child's daily screen time goal is reached, `MedicationGiven`/`MedicationDue` for medications, `ShoppingHeadingOut` for the shopping list. Anything else opens the inbox.
String pushRoute(Map<String, dynamic> data) {
  final chatKey = data['chatKey'];
  if (data['kind'] == 'Message' && chatKey is String && chatKey.isNotEmpty) return '/chats/$chatKey';
  if (data['kind'] == 'ScreenTimeGoal') return '/screen-time';
  if (data['kind'] == 'ShoppingHeadingOut') return '/shopping';
  if (data['kind'] == 'MedicationGiven' || data['kind'] == 'MedicationDue') return '/medications';
  return switch (data['targetKind']) {
    'Task' => '/tasks',
    'Event' => '/calendar',
    _ => '/notifications',
  };
}

/// The device side of push. [FirebasePushMessaging] in the app, a fake in tests.
abstract interface class PushMessaging {
  /// False when push is not available (no google-services.json, unsupported platform). Everything else is then a no-op.
  Future<bool> init();

  /// Asks the user (Android 13+, iOS). Returns false if they said no.
  Future<bool> requestPermission();
  Future<String?> token();
  Stream<String> get tokenRefresh;

  /// Pushes that arrive while the app is open. Android and iOS do not show those by themselves.
  Stream<PushEvent> get foreground;

  /// Taps on a push while the app was in the background.
  Stream<PushEvent> get opened;

  /// The push whose tap started the app, if any.
  Future<PushEvent?> initialOpened();
  Future<void> deleteToken();
}

/// Firebase Cloud Messaging. Firebase reads its settings from `android/app/google-services.json`
/// (and `ios/Runner/GoogleService-Info.plist`); without them [init] returns false and the app runs without push.
class FirebasePushMessaging implements PushMessaging {
  static PushEvent _event(RemoteMessage m) => PushEvent(title: m.notification?.title, body: m.notification?.body, data: m.data);

  FirebaseMessaging get _fm => FirebaseMessaging.instance;

  @override
  Future<bool> init() async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return false;
    try {
      if (Firebase.apps.isEmpty) await Firebase.initializeApp();
      return true;
    } catch (e) {
      debugPrint('push: Firebase is not configured ($e)');
      return false;
    }
  }

  @override
  Future<bool> requestPermission() async {
    final settings = await _fm.requestPermission();
    return settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;
  }

  // The server sends with FCM HTTP v1 `message.token`, which takes this registration token. The newer register()/
  // onRegistered API hands out an installation id for direct send instead; switch both sides together later.
  @override
  // ignore: deprecated_member_use
  Future<String?> token() => _fm.getToken();

  @override
  // ignore: deprecated_member_use
  Stream<String> get tokenRefresh => _fm.onTokenRefresh;

  @override
  Stream<PushEvent> get foreground => FirebaseMessaging.onMessage.map(_event);

  @override
  Stream<PushEvent> get opened => FirebaseMessaging.onMessageOpenedApp.map(_event);

  @override
  Future<PushEvent?> initialOpened() async {
    final m = await _fm.getInitialMessage();
    return m == null ? null : _event(m);
  }

  @override
  // ignore: deprecated_member_use
  Future<void> deleteToken() => _fm.deleteToken();
}

/// Push is off: before Firebase is set up, on desktop, and in widget tests.
class NoPushMessaging implements PushMessaging {
  @override
  Future<bool> init() async => false;
  @override
  Future<bool> requestPermission() async => false;
  @override
  Future<String?> token() async => null;
  @override
  Stream<String> get tokenRefresh => const Stream.empty();
  @override
  Stream<PushEvent> get foreground => const Stream.empty();
  @override
  Stream<PushEvent> get opened => const Stream.empty();
  @override
  Future<PushEvent?> initialOpened() async => null;
  @override
  Future<void> deleteToken() async {}
}

final pushMessagingProvider = Provider<PushMessaging>((ref) {
  // `flutter test` sets FLUTTER_TEST; plugins have no native side there.
  if (!kIsWeb && Platform.environment.containsKey('FLUTTER_TEST')) return NoPushMessaging();
  return FirebasePushMessaging();
});

/// Shows foreground pushes as a snack bar. Set on MaterialApp.
final hallyMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// Connects the device to the signed-in user: registers the FCM token with the API, follows token refreshes,
/// opens the right screen when a push is tapped, and shows pushes that arrive while the app is open.
class PushController {
  PushController(this._messaging, this._api, this._open, {this.onForeground});

  final PushMessaging _messaging;
  final ApiClient _api;
  final void Function(String route) _open;
  final void Function(PushEvent event)? onForeground;
  final _subscriptions = <StreamSubscription<Object?>>[];
  String? _token;
  bool _disposed = false;

  /// The token the API knows for this device, once registered.
  String? get registeredToken => _token;

  Future<void> start() async {
    if (!await _messaging.init() || _disposed) return;
    _subscriptions
      ..add(_messaging.opened.listen((e) => _open(pushRoute(e.data))))
      ..add(_messaging.foreground.listen((e) => onForeground?.call(e)))
      ..add(_messaging.tokenRefresh.listen(_register));

    final initial = await _messaging.initialOpened();
    if (initial != null && !_disposed) _open(pushRoute(initial.data));

    if (!await _messaging.requestPermission() || _disposed) return;
    final token = await _messaging.token();
    if (token != null) await _register(token);
  }

  Future<void> _register(String token) async {
    if (_disposed) return;
    try {
      await _api.dio.put<void>('/api/v1/me/devices', data: {'platform': _platform, 'token': token});
      _token = token;
    } catch (e) {
      // The next app start registers again.
      debugPrint('push: device registration failed (${ApiClient.toApiException(e).status})');
    }
  }

  /// Call before signing out, while the session is still valid, so this device stops getting that user's pushes.
  Future<void> unregister() async {
    final token = _token;
    if (token == null) return;
    _token = null;
    try {
      await _api.dio
          .delete<void>('/api/v1/me/devices', queryParameters: {'token': token})
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // Best effort: a token the server still has is cleaned up when FCM reports it unregistered.
    }
  }

  static String get _platform => !kIsWeb && Platform.isIOS ? 'ios' : 'android';

  void dispose() {
    _disposed = true;
    for (final s in _subscriptions) {
      s.cancel();
    }
  }
}

/// One controller per signed-in user. HallyApp watches it so it starts with the app.
final pushControllerProvider = Provider<PushController?>((ref) {
  final userId = ref.watch(meProvider.select((me) => me.valueOrNull?.id));
  if (userId == null) return null;

  void open(String route) {
    final router = ref.read(routerProvider);
    // Calendar is a tab; the others open on top of the current screen.
    route == '/calendar' ? router.go(route) : router.push(route);
  }

  final controller = PushController(
    ref.watch(pushMessagingProvider),
    ref.watch(apiClientProvider),
    open,
    onForeground: (e) {
      final familyId = ref.read(meProvider).valueOrNull?.primaryFamily?.id;
      if (e.data['kind'] == 'Message') {
        // Chats update live; just refresh the unread badge.
        if (familyId != null) ref.invalidate(chatListProvider(familyId));
        return;
      }
      ref.invalidate(inboxProvider);
      final text = [e.title, e.body].whereType<String>().where((s) => s.isNotEmpty).join('\n');
      final messenger = hallyMessengerKey.currentState;
      if (text.isEmpty || messenger == null) return;
      messenger.showSnackBar(SnackBar(
        content: Text(text),
        action: SnackBarAction(label: AppLocalizations.of(messenger.context).pushOpen, onPressed: () => open(pushRoute(e.data))),
      ));
    },
  );
  unawaited(controller.start());
  ref.onDispose(controller.dispose);
  return controller;
});
