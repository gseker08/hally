import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:home_widget/home_widget.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'app.dart';
import 'core/config/app_config.dart';
import 'core/locale/app_language.dart';
import 'features/notifications/ios_background.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // iPhone widgets read what the app saves in the shared App Group.
  if (!kIsWeb && Platform.isIOS) await HomeWidget.setAppGroupId(iosAppGroup);
  final language = await SecureLanguageStorage().read();
  void run() => runApp(ProviderScope(
        overrides: [initialLanguageProvider.overrideWithValue(language)],
        child: const HallyApp(),
      ));

  // Crash and error reports only when a DSN is passed (--dart-define=SENTRY_DSN=...). No PII is sent:
  // no user identity, IP or request bodies, and no screenshots or view hierarchy.
  if (AppConfig.sentryDsn.isEmpty) {
    run();
    return;
  }

  await SentryFlutter.init(
    (o) {
      o.dsn = AppConfig.sentryDsn;
      o.environment = AppConfig.environment;
      o.sendDefaultPii = false;
      o.attachScreenshot = false;
      o.attachViewHierarchy = false;
      o.tracesSampleRate = 0.1;
    },
    appRunner: run,
  );
}
