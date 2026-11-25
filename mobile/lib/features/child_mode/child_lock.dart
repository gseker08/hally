import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';

/// What the Android screen lock needs and whether it runs.
class ChildLockStatus {
  const ChildLockStatus({this.supported = false, this.usageAccess = false, this.overlay = false, this.running = false});

  final bool supported;
  final bool usageAccess;
  final bool overlay;
  final bool running;

  bool get ready => usageAccess && overlay;
}

/// The child phone's screen lock (Android, `ChildLock.kt`). On other platforms nothing happens yet: iPhone needs
/// Apple's Screen Time API, which comes later.
class ChildLockController {
  ChildLockController([MethodChannel? channel]) : _channel = channel ?? const MethodChannel('hally/child_lock');

  final MethodChannel _channel;

  static bool get supported => !kIsWeb && Platform.isAndroid;

  Future<ChildLockStatus> status() async {
    if (!supported) return const ChildLockStatus();
    final s = await _channel.invokeMapMethod<String, bool>('status') ?? const {};
    return ChildLockStatus(supported: true, usageAccess: s['usageAccess'] ?? false, overlay: s['overlay'] ?? false, running: s['running'] ?? false);
  }

  Future<void> openUsageAccess() => _channel.invokeMethod<void>('openUsageAccess');

  Future<void> openOverlay() => _channel.invokeMethod<void>('openOverlay');

  Future<void> start(String token) => _channel.invokeMethod<void>('start', {'token': token, 'baseUrl': AppConfig.apiBaseUrl});

  Future<void> stop() async {
    if (supported) await _channel.invokeMethod<void>('stop');
  }
}

final childLockProvider = Provider<ChildLockController>((ref) => ChildLockController());

final childLockStatusProvider = FutureProvider.autoDispose<ChildLockStatus>((ref) => ref.watch(childLockProvider).status());
