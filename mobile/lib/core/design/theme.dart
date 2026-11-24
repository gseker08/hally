import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';

ThemeData buildHallyTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final ink = dark ? HallyColors.inkDark : HallyColors.ink;
  final muted = dark ? HallyColors.inkMutedDark : HallyColors.inkMuted;
  final surface = dark ? HallyColors.surfaceDark : HallyColors.surface;
  final line = dark ? HallyColors.lineDark : HallyColors.line;

  final scheme = ColorScheme.fromSeed(
    seedColor: HallyColors.cherry,
    brightness: brightness,
    // Primary = deep cherry for actions (white text 6.8:1). Dark: the light cherry carries dark text.
    primary: dark ? HallyColors.cherryStrongDark : HallyColors.cherryStrong,
    onPrimary: dark ? HallyColors.canvasDark : Colors.white,
    primaryContainer: dark ? HallyColors.cherrySoftDark : HallyColors.cherrySoft,
    onPrimaryContainer: dark ? HallyColors.cherryStrongDark : HallyColors.cherryStrong,
    secondary: dark ? HallyColors.sageDark : HallyColors.sage,
    onSecondary: dark ? HallyColors.canvasDark : Colors.white,
    secondaryContainer: dark ? HallyColors.sagePastelDark : HallyColors.sagePastel,
    onSecondaryContainer: ink,
    tertiary: dark ? HallyColors.peachDark : HallyColors.peach,
    tertiaryContainer: dark ? HallyColors.peachPastelDark : HallyColors.peachPastel,
    onTertiaryContainer: ink,
    error: dark ? HallyColors.errorDark : HallyColors.error,
    onError: dark ? HallyColors.canvasDark : Colors.white,
    errorContainer: dark ? HallyColors.peachPastelDark : HallyColors.peachPastel,
    onErrorContainer: dark ? HallyColors.errorDark : HallyColors.error,
    surface: surface,
    surfaceContainerLowest: surface,
    surfaceContainerLow: dark ? HallyColors.surfaceDark : HallyColors.surface,
    surfaceContainer: dark ? HallyColors.surfaceAltDark : HallyColors.canvas,
    surfaceContainerHigh: dark ? HallyColors.surfaceAltDark : HallyColors.canvas,
    surfaceContainerHighest: dark ? HallyColors.lineDark : HallyColors.line,
    onSurface: ink,
    onSurfaceVariant: muted,
    outline: line,
    outlineVariant: line,
  );

  final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: HallyFonts.body);
  TextStyle? display(TextStyle? s, FontWeight w, {double? spacing}) =>
      s?.copyWith(fontFamily: HallyFonts.display, fontWeight: w, color: ink, letterSpacing: spacing);
  final text = base.textTheme
      .apply(bodyColor: ink, displayColor: ink)
      .copyWith(
        displayMedium: display(base.textTheme.displayMedium, FontWeight.w800, spacing: -1.5),
        displaySmall: display(base.textTheme.displaySmall, FontWeight.w800, spacing: -1),
        headlineMedium: display(base.textTheme.headlineMedium, FontWeight.w700, spacing: -0.5),
        headlineSmall: display(base.textTheme.headlineSmall, FontWeight.w700, spacing: -0.3),
        titleLarge: display(base.textTheme.titleLarge, FontWeight.w700, spacing: -0.2),
        titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600, color: ink),
        titleSmall: base.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600, color: ink),
        bodyLarge: base.textTheme.bodyLarge?.copyWith(height: 1.45, color: ink),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(height: 1.4, color: muted),
        // Minimum readable sizes: Material's defaults (11–12px) are too small for tired parents on the go.
        bodySmall: base.textTheme.bodySmall?.copyWith(color: muted, fontSize: 13, height: 1.35),
        labelMedium: base.textTheme.labelMedium?.copyWith(fontSize: 13),
        labelSmall: base.textTheme.labelSmall?.copyWith(fontSize: 12),
        labelLarge: base.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700, fontSize: 16),
      );

  final buttonShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(HallyRadius.md));
  const buttonText = TextStyle(fontFamily: HallyFonts.body, fontWeight: FontWeight.w700, fontSize: 16);

  return base.copyWith(
    scaffoldBackgroundColor: dark ? HallyColors.canvasDark : HallyColors.canvas,
    textTheme: text,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      foregroundColor: ink,
      systemOverlayStyle: dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      titleTextStyle: text.titleLarge?.copyWith(fontSize: 22),
    ),
    cardTheme: CardThemeData(
      color: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: const EdgeInsets.only(bottom: HallySpace.sm + 2),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HallyRadius.lg),
        side: BorderSide(color: dark ? line : line.withValues(alpha: 0.7)),
      ),
      shadowColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
    ),
    listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: HallySpace.md, vertical: 2)),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(56),
        shape: buttonShape,
        textStyle: buttonText,
        elevation: 0,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(56),
        shape: buttonShape,
        textStyle: buttonText,
        side: BorderSide(color: line, width: 1.5),
        foregroundColor: ink,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        textStyle: buttonText.copyWith(fontSize: 15),
        shape: buttonShape,
        foregroundColor: scheme.primary,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? HallyColors.surfaceAltDark : HallyColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: HallySpace.md, vertical: HallySpace.md),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(HallyRadius.md), borderSide: BorderSide(color: line)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(HallyRadius.md), borderSide: BorderSide(color: line, width: 1.5)),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(HallyRadius.md),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      hintStyle: TextStyle(color: muted),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(HallyRadius.pill)),
      side: BorderSide(color: line),
      labelStyle: TextStyle(fontFamily: HallyFonts.body, fontWeight: FontWeight.w600, color: ink, fontSize: 13),
      backgroundColor: surface,
      selectedColor: HallyColors.softOf(HallyColors.cherry, brightness),
      secondarySelectedColor: HallyColors.softOf(HallyColors.cherry, brightness),
      checkmarkColor: scheme.primary,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: line,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(HallyRadius.xl))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(HallyRadius.xl)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? HallyColors.inkDark : HallyColors.ink,
      actionTextColor: dark ? HallyColors.cherryStrong : HallyColors.cherrySoft,
      contentTextStyle: TextStyle(fontFamily: HallyFonts.body, color: dark ? HallyColors.canvasDark : Colors.white, fontWeight: FontWeight.w500),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(HallyRadius.md)),
    ),
    dividerTheme: DividerThemeData(color: line, thickness: 1),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary, linearTrackColor: line, circularTrackColor: line),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      elevation: 0,
      highlightElevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(HallyRadius.md)),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: HallyColors.softOf(HallyColors.cherry, brightness),
        selectedForegroundColor: dark ? HallyColors.cherryStrongDark : HallyColors.cherryStrong,
        side: BorderSide(color: line),
        textStyle: const TextStyle(fontFamily: HallyFonts.body, fontWeight: FontWeight.w600),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? scheme.onPrimary : muted),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? scheme.primary : line),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.transparent : line),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: surface,
      indicatorColor: HallyColors.softOf(HallyColors.cherry, brightness),
      surfaceTintColor: Colors.transparent,
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: dark ? HallyColors.cherryDark : HallyColors.cherryStrong,
      unselectedLabelColor: muted,
      indicatorColor: dark ? HallyColors.cherryDark : HallyColors.cherry,
      dividerColor: line,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(HallyRadius.md), side: BorderSide(color: line)),
    ),
    datePickerTheme: DatePickerThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(HallyRadius.xl)),
    ),
    timePickerTheme: TimePickerThemeData(
      backgroundColor: surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(HallyRadius.xl)),
    ),
  );
}
