import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:home_widget/home_widget.dart';
import 'package:quick_actions/quick_actions.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/locale/app_language.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../router.dart';

/// The app icon shortcut (long press → "Hally'ye söyle").
const voiceShortcutType = 'hally.voice';

/// The microphone on the Android "Bugün" widget opens the app with this link.
bool isVoiceLaunchUri(Uri? uri) => uri != null && uri.scheme == 'hally' && uri.host == 'voice';

/// Ways into the assistant already listening from outside the app: the app icon shortcut and the widget's
/// microphone. Waits for sign-in, then opens `/assistant?voice=1`. A no-op off the phone.
final voiceLaunchProvider = Provider<void>((ref) {
  if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;

  var pending = false;
  void tryOpen() {
    if (!pending || ref.read(meProvider).valueOrNull?.primaryFamily == null) return;
    pending = false;
    // Let the router settle on its first screen after sign-in so the push lands on top of it.
    Future<void>.delayed(const Duration(milliseconds: 300), () => ref.read(routerProvider).push('/assistant?voice=1'));
  }

  void request() {
    pending = true;
    tryOpen();
  }

  ref.listen(meProvider, (_, __) => tryOpen());

  const actions = QuickActions();
  Future<void> setItems() async {
    final language = ref.read(languageProvider);
    final l10n = lookupAppLocalizations(language.locale ?? resolveDeviceLocale(ref.read(deviceLocaleProvider)));
    await actions.setShortcutItems([ShortcutItem(type: voiceShortcutType, localizedTitle: l10n.voiceShortcut, icon: 'ic_shortcut_mic')]);
  }

  unawaited(() async {
    try {
      await actions.initialize((type) {
        if (type == voiceShortcutType) request();
      });
      await setItems();
    } catch (e) {
      debugPrint('quick actions: $e');
    }
  }());
  ref.listen(languageProvider, (_, __) => unawaited(setItems().catchError((Object e) => debugPrint('quick actions: $e'))));

  if (Platform.isAndroid) {
    unawaited(HomeWidget.initiallyLaunchedFromHomeWidget().then((uri) {
      if (isVoiceLaunchUri(uri)) request();
    }).catchError((Object e) => debugPrint('widget launch: $e')));
    final sub = HomeWidget.widgetClicked.listen((uri) {
      if (isVoiceLaunchUri(uri)) request();
    });
    ref.onDispose(sub.cancel);
  }
});
