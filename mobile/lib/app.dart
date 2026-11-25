import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/config/app_config.dart';
import 'core/design/theme.dart';
import 'core/locale/app_language.dart';
import 'features/assistant/voice_launch.dart';
import 'features/billing/billing_repository.dart';
import 'features/home/now_widget.dart';
import 'features/home/today_widget.dart';
import 'features/notifications/device_notifications.dart';
import 'features/notifications/push.dart';
import 'l10n/gen/app_localizations.dart';
import 'router.dart';

class HallyApp extends ConsumerWidget {
  const HallyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Registers this device for push once someone is signed in (a no-op until Firebase is set up).
    ref.watch(pushControllerProvider);
    // Keeps the Android home screen "Today" widget up to date (a no-op elsewhere).
    ref.watch(todayWidgetSyncProvider);
    // Ongoing lock screen / status bar notification while a timer this user started runs (Android).
    ref.watch(deviceNotificationsSyncProvider);
    // Home screen "Şu an" widget with the family's running timers (Android).
    ref.watch(nowWidgetSyncProvider);
    // Store purchases that finish in the background (a pending payment that cleared) reach the server.
    ref.watch(storePurchaseSyncProvider);
    // "Hally'ye söyle" from the app icon shortcut or the widget's microphone.
    ref.watch(voiceLaunchProvider);
    return MaterialApp.router(
      scaffoldMessengerKey: hallyMessengerKey,
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: buildHallyTheme(Brightness.light),
      darkTheme: buildHallyTheme(Brightness.dark),
      routerConfig: ref.watch(routerProvider),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      // null follows the device. The language can be changed in Family > Language.
      locale: ref.watch(languageProvider).locale,
      // Turkish is the default for unsupported device languages (Türkiye is the launch market).
      localeResolutionCallback: (device, supported) => resolveDeviceLocale(device),
    );
  }
}
