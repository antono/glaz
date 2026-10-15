import 'package:flutter/material.dart';

/// Frame's display palette, so the phone looks like the glasses.
///
/// Same names and order as frame.display's colour table; the menu on the
/// glasses uses WHITE for the cursor, GREY for the rest, SKYBLUE for the
/// breadcrumb and RED for a low battery.
abstract final class FrameColors {
  static const void_ = Color(0xFF000000);
  static const white = Color(0xFFFFFFFF);
  static const grey = Color(0xFF9D9D9D);
  static const red = Color(0xFFBE2633);
  static const pink = Color(0xFFE06F8B);
  static const orange = Color(0xFFEB8931);
  static const yellow = Color(0xFFF7E26B);
  static const green = Color(0xFF44891A);
  static const lightGreen = Color(0xFFA3CE27);
  static const nightBlue = Color(0xFF005784);
  static const seaBlue = Color(0xFF31A2F2);
  static const skyBlue = Color(0xFFB2DCEF);

  /// Not on the glasses: a raised surface, one step above the OLED black.
  static const surface = Color(0xFF111114);
  static const outline = Color(0xFF2A2A30);
}

/// Monospace for headings and labels, echoing the glasses' fixed-width font.
const monoFamily = 'monospace';

ThemeData glazTheme() {
  const scheme = ColorScheme.dark(
    primary: FrameColors.lightGreen,
    onPrimary: FrameColors.void_,
    secondary: FrameColors.skyBlue,
    onSecondary: FrameColors.void_,
    tertiary: FrameColors.pink,
    error: FrameColors.red,
    surface: FrameColors.void_,
    onSurface: FrameColors.white,
    onSurfaceVariant: FrameColors.grey,
    surfaceContainerLow: FrameColors.surface,
    surfaceContainer: FrameColors.surface,
    surfaceContainerHigh: FrameColors.surface,
    outline: FrameColors.outline,
    outlineVariant: FrameColors.outline,
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true);
  final text = base.textTheme.copyWith(
    headlineMedium: base.textTheme.headlineMedium?.copyWith(
      fontFamily: monoFamily,
      fontWeight: FontWeight.bold,
      letterSpacing: 4,
    ),
    titleMedium: base.textTheme.titleMedium?.copyWith(
      fontFamily: monoFamily,
      fontWeight: FontWeight.bold,
    ),
    labelSmall: base.textTheme.labelSmall?.copyWith(fontFamily: monoFamily),
  );
  return base.copyWith(
    scaffoldBackgroundColor: FrameColors.void_,
    textTheme: text,
    appBarTheme: AppBarTheme(
      backgroundColor: FrameColors.void_,
      surfaceTintColor: Colors.transparent,
      centerTitle: true,
      titleTextStyle: text.titleMedium?.copyWith(
        color: FrameColors.skyBlue,
        letterSpacing: 2,
      ),
    ),
    cardTheme: const CardThemeData(
      color: FrameColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        side: BorderSide(color: FrameColors.outline),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: FrameColors.surface,
      indicatorColor: FrameColors.green.withValues(alpha: 0.35),
      labelTextStyle: WidgetStatePropertyAll(text.labelSmall),
    ),
    dividerTheme: const DividerThemeData(color: FrameColors.outline),
    expansionTileTheme: const ExpansionTileThemeData(
      shape: Border(),
      collapsedShape: Border(),
      iconColor: FrameColors.skyBlue,
      collapsedIconColor: FrameColors.grey,
    ),
  );
}
