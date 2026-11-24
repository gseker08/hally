import 'package:flutter/material.dart';

/// Hally design tokens ("Soft Living & Soft Cherry"). Keep raw colour values here only; widgets read them through
/// the theme, [HallyColors] helpers or [HallyModule].
///
/// Light mode: warm cream canvas, white cards, natural dark-green ink and six controlled pastels.
/// Dark mode is its own palette (deep forest canvas, muted pastel tints, light accents), not an inverted light one.
abstract final class HallyColors {
  // ── Brand ────────────────────────────────────────────────────────────────
  /// Soft cherry: the brand colour (logo, selected states, links).
  static const cherry = Color(0xFFAD5268);

  /// Deep cherry: primary actions (filled buttons, + button). White text is 6.8:1.
  static const cherryStrong = Color(0xFF914057);

  /// Blush tint behind cherry accents.
  static const cherrySoft = Color(0xFFF3E4E7);

  /// Logo stem.
  static const cherryStem = Color(0xFF6E3A44);

  /// Logo leaf (sage).
  static const leaf = Color(0xFF8FAE8F);

  static const cherryDark = Color(0xFFD88A9D);
  static const cherryStrongDark = Color(0xFFE6A3B3);
  static const cherrySoftDark = Color(0xFF3E2A30);

  // ── Pastels (light backgrounds for module identity) ─────────────────────
  static const sagePastel = Color(0xFFDCE5D7);
  static const powderPastel = Color(0xFFEBDCD6);
  static const lavenderPastel = Color(0xFFE3DFF0);
  static const butterPastel = Color(0xFFEAE5CC);
  static const peachPastel = Color(0xFFF1DFCF);
  static const mistPastel = Color(0xFFDFE8EE);

  // Dark-mode pastels: the same hues, deep and muted so light text stays readable.
  static const sagePastelDark = Color(0xFF2B3832);
  static const powderPastelDark = Color(0xFF3B2D30);
  static const lavenderPastelDark = Color(0xFF302D40);
  static const butterPastelDark = Color(0xFF37352A);
  static const peachPastelDark = Color(0xFF3C3029);
  static const mistPastelDark = Color(0xFF2A3640);

  // ── Accents (icons, rings, progress) — deeper tones of each pastel ─────
  static const sage = Color(0xFF5E7D68);
  static const powder = Color(0xFFA0606E);
  static const lavender = Color(0xFF7368A8);
  static const butter = Color(0xFF9C8530);
  static const peach = Color(0xFFC07A4C);
  static const mist = Color(0xFF5B8099);

  // Light accents for dark mode.
  static const sageDark = Color(0xFF9FBFA5);
  static const powderDark = Color(0xFFE0A9B5);
  static const lavenderDark = Color(0xFFB9AFE6);
  static const butterDark = Color(0xFFD9C77E);
  static const peachDark = Color(0xFFE8A36F);
  static const mistDark = Color(0xFF9EC0D4);

  // ── Semantic aliases kept for existing call sites ───────────────────────
  /// Done / success.
  static const mint = sage;
  static const mintDeep = Color(0xFF4C6A57);
  static const mintSoft = sagePastel;

  /// Waiting, overdue, "needs attention" (never red).
  static const apricot = peach;
  static const apricotSoft = peachPastel;
  static const rose = powder;
  static const roseSoft = powderPastel;
  static const sky = mist;
  static const skySoft = mistPastel;

  /// Learning (homework, reading).
  static const study = lavender;

  /// Stars and rewards.
  static const star = butter;

  // ── Neutrals ─────────────────────────────────────────────────────────────
  /// Main text: deep natural green.
  static const ink = Color(0xFF374B45);

  /// Secondary text. The brief's #65766A is 4.36:1 on cream, just under WCAG AA, so this is nudged one step darker (4.8:1).
  static const inkMuted = Color(0xFF5E6F63);
  static const line = Color(0xFFE7E1D8);
  static const canvas = Color(0xFFF7F3ED);
  static const surface = Color(0xFFFFFFFF);

  static const inkDark = Color(0xFFEEF0EA);
  static const inkMutedDark = Color(0xFFA9B5AC);
  static const canvasDark = Color(0xFF1B2120);
  static const surfaceDark = Color(0xFF242B29);
  static const surfaceAltDark = Color(0xFF2C3431);
  static const lineDark = Color(0xFF38413D);

  /// Errors and overdue states use a warm orange, never red, and always come with an icon and text.
  static const error = Color(0xFFA35A2E);
  static const errorDark = Color(0xFFE8A36F);

  /// Child identity colours (API keys sky, mint, lavender, sun, teal, indigo): muted, natural and dark enough for
  /// a white initial. Cherry (brand) and orange (delays) are left out so a child never reads as an alert.
  static const childSky = mist;
  static const childMint = sage;
  static const childLavender = lavender;
  static const childSun = Color(0xFF8F7A2A);
  static const childTeal = Color(0xFF4E8783);
  static const childIndigo = Color(0xFF5E6A9E);

  /// Avatar colours, picked by a stable hash of the member's name.
  static const avatars = [cherry, sage, peach, lavender, mist];

  static final Map<Color, (Color, Color, Color)> _pastels = {
    sage: (sagePastel, sagePastelDark, sageDark),
    mintDeep: (sagePastel, sagePastelDark, sageDark),
    powder: (powderPastel, powderPastelDark, powderDark),
    lavender: (lavenderPastel, lavenderPastelDark, lavenderDark),
    butter: (butterPastel, butterPastelDark, butterDark),
    peach: (peachPastel, peachPastelDark, peachDark),
    mist: (mistPastel, mistPastelDark, mistDark),
    cherry: (cherrySoft, cherrySoftDark, cherryDark),
    cherryStrong: (cherrySoft, cherrySoftDark, cherryStrongDark),
    error: (peachPastel, peachPastelDark, errorDark),
  };

  /// The accent itself as it should be drawn in [brightness]: palette accents get their light dark-mode twin.
  static Color accent(Color accent, Brightness brightness) =>
      brightness == Brightness.dark ? (_pastels[accent]?.$3 ?? Color.lerp(accent, Colors.white, 0.35)!) : accent;

  /// Accent colour for text and icons on its own pastel ([softOf]): deepened towards the ink in light mode and the
  /// light twin in dark mode, so small labels reach WCAG AA on the pastel.
  static Color readableOn(Color accent, Brightness brightness) => brightness == Brightness.dark
      ? (_pastels[accent]?.$3 ?? Color.lerp(accent, Colors.white, 0.35)!)
      : Color.lerp(accent, ink, 0.6)!;

  /// Pastel background for an accent: the palette's exact pastel when the accent is a palette colour, otherwise a tint.
  static Color softOf(Color accent, Brightness brightness) {
    final p = _pastels[accent];
    if (p != null) return brightness == Brightness.dark ? p.$2 : p.$1;
    return accent.withValues(alpha: brightness == Brightness.dark ? 0.22 : 0.13);
  }
}

/// Each module has one controlled pastel identity. Use the accent with [HallyColors.softOf] for its background and
/// [HallyColors.readableOn] for icons and labels on it.
abstract final class HallyModule {
  static const calendar = HallyColors.lavender;
  static const tasks = HallyColors.sage;
  static const kids = HallyColors.peach;
  static const messages = HallyColors.mist;
  static const shopping = HallyColors.butter;
  static const health = HallyColors.powder;
  static const medications = HallyColors.powder;
  static const sleep = HallyColors.lavender;
  static const feeding = HallyColors.peach;
  static const screenTime = HallyColors.mist;
  static const study = HallyColors.lavender;
  static const habits = HallyColors.peach;
  static const rewards = HallyColors.butter;
  static const expenses = HallyColors.sage;
  static const duties = HallyColors.mist;

  /// The Hally assistant: sage, so AI never competes with the cherry brand actions.
  static const assistant = HallyColors.sage;
}

abstract final class HallyGradients {
  /// Brand hero: a quiet cherry shift, no neon glow.
  static const hero = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF914057), Color(0xFFAD5268)],
  );

  /// Hally assistant moments: sage pastel with a hint of cream.
  static const magic = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFDCE5D7), Color(0xFFE6ECDF)],
  );

  static const magicDark = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF2B3832), Color(0xFF26312C)],
  );

  /// Cards that carry white body text: every stop keeps white text at 5:1 or more.
  static const magicCard = hero;

  /// Readable sage for surfaces with white text (swipe-to-complete).
  static const mintDeep = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF4C6A57), Color(0xFF5E7D68)],
  );

  static const mint = LinearGradient(colors: [Color(0xFF5E7D68), Color(0xFF6F8C78)]);

  static const apricot = LinearGradient(colors: [Color(0xFFC07A4C), Color(0xFFCB8C61)]);

  static const cherry = LinearGradient(colors: [Color(0xFF914057), Color(0xFF9C4960)]);
}

abstract final class HallyShadows {
  /// Light, warm, barely-there card lift.
  static List<BoxShadow> soft(Brightness b) => b == Brightness.dark
      ? const []
      : [BoxShadow(color: const Color(0xFF374B45).withValues(alpha: 0.06), blurRadius: 18, offset: const Offset(0, 6))];

  static List<BoxShadow> glow(Color c) => [BoxShadow(color: c.withValues(alpha: 0.18), blurRadius: 16, offset: const Offset(0, 6))];

  /// Floating bars (bottom navigation).
  static List<BoxShadow> float(Brightness b) => [
        BoxShadow(color: const Color(0xFF374B45).withValues(alpha: b == Brightness.dark ? 0.0 : 0.08), blurRadius: 24, offset: const Offset(0, 8)),
        if (b == Brightness.dark) BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 24, offset: const Offset(0, 8)),
      ];
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
