import 'package:flutter/material.dart';

/// Hally design tokens. Keep raw values here only; widgets read them through the theme or these classes.
abstract final class HallyColors {
  /// Brand primary ("Kiraz"). Dark-mode counterparts are used by the theme's dark scheme.
  static const cherry = Color(0xFFA8133C);
  static const cherryStrong = Color(0xFF8E0F33);
  static const cherrySoft = Color(0xFFFBE6EC);
  static const cherryDark = Color(0xFFE25C7C);
  static const cherryStrongDark = Color(0xFFF08AA2);
  static const cherrySoftDark = Color(0xFF3A1520);
  static const mint = Color(0xFF3FB59A);
  static const mintDeep = Color(0xFF23937A);
  static const mintSoft = Color(0xFFE2F5EF);
  static const apricot = Color(0xFFE08A4C);
  static const apricotSoft = Color(0xFFFBEADD);
  static const rose = Color(0xFFE27AA6);
  static const roseSoft = Color(0xFFFBE7F0);
  static const sky = Color(0xFF4FA3E0);
  static const skySoft = Color(0xFFE3F0FB);
  static const ink = Color(0xFF231A1D);
  static const inkMuted = Color(0xFF625A5E);
  static const line = Color(0xFFF0E4E7);
  static const canvas = Color(0xFFFBF5F6);
  static const surface = Color(0xFFFFFFFF);
  static const canvasDark = Color(0xFF1A1215);
  static const surfaceDark = Color(0xFF251B1F);
  static const lineDark = Color(0xFF3A2A2F);
  /// Errors and overdue states use orange, never red, and always come with an icon and text.
  static const error = Color(0xFFC2621C);

  /// Avatar colours, picked by a stable hash of the member's name.
  static const avatars = [cherry, mint, apricot, rose, sky];

  /// Accent colour for text on its own soft tint ([softOf]): darkened in light mode and lightened in dark mode
  /// so small labels reach WCAG AA (raw apricot or mint on their tint is only ~2.4:1).
  static Color readableOn(Color accent, Brightness brightness) => brightness == Brightness.dark
      ? Color.lerp(accent, Colors.white, 0.35)!
      : Color.lerp(accent, ink, 0.45)!;

  /// Tinted background for an accent colour that also works in dark mode.
  static Color softOf(Color accent, Brightness brightness) =>
      accent.withValues(alpha: brightness == Brightness.dark ? 0.22 : 0.13);
}

abstract final class HallyGradients {
  /// Brand hero: deep cherry into a warm coral glow.
  static const hero = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF8E0F33), Color(0xFFC2224E), Color(0xFFEE8B78)],
  );

  /// Sunrise accent used for the AI ("Hally") moments.
  static const magic = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF8E0F33), Color(0xFFC2224E), Color(0xFFEE8B78)],
  );

  /// Readable variant of [magic] for cards that carry white body text: every stop keeps white text at 4.6:1 or more.
  static const magicCard = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF8E0F33), Color(0xFFA8133C), Color(0xFFB4472A)],
  );

  /// Readable mint for surfaces with white text (swipe-to-complete).
  static const mintDeep = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF1B7A65), Color(0xFF23937A)],
  );

  static const mint = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF3FB59A), Color(0xFF6FD3B4)],
  );

  static const apricot = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFE08A4C), Color(0xFFF2B36F)],
  );

  static const cherry = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF8E0F33), Color(0xFFC2224E)],
  );
}

abstract final class HallyShadows {
  static List<BoxShadow> soft(Brightness b) => b == Brightness.dark
      ? const []
      : [BoxShadow(color: const Color(0xFF5A1023).withValues(alpha: 0.07), blurRadius: 24, offset: const Offset(0, 8))];

  static List<BoxShadow> glow(Color c) => [BoxShadow(color: c.withValues(alpha: 0.35), blurRadius: 24, offset: const Offset(0, 10))];
}

abstract final class HallySpace {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
  static const xxl = 48.0;
}

abstract final class HallyRadius {
  static const sm = 12.0;
  static const md = 18.0;
  static const lg = 24.0;
  static const xl = 32.0;
  static const pill = 999.0;
}

abstract final class HallyMotion {
  static const fast = Duration(milliseconds: 160);
  static const medium = Duration(milliseconds: 280);
  static const slow = Duration(milliseconds: 450);
  static const curve = Curves.easeOutCubic;
}

abstract final class HallyFonts {
  /// Display / headings. Bundled under assets/fonts (SIL OFL).
  static const display = 'Bricolage Grotesque';
  static const body = 'Figtree';
}
