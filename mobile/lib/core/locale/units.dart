import 'package:flutter/widgets.dart';

/// The app's language code ("tr", "en", "de", …) for code that formats text by hand.
String langOf(BuildContext context) => Localizations.localeOf(context).languageCode;

/// Short hour/minute units for durations such as "1 sa 05 dk", "1 h 05 min" or "1 Std. 05 Min.".
({String h, String min}) durationUnits(String languageCode) => switch (languageCode) {
      'tr' => (h: 'sa', min: 'dk'),
      'de' => (h: 'Std.', min: 'Min.'),
      _ => (h: 'h', min: 'min'),
    };
