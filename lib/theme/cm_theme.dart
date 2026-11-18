import 'package:flutter/material.dart';

class CmTheme {
  static const String fontFamily = 'CheckMate';

  static const Color navy = Color(0xFF111C33);
  static const Color emeraldSuccess = Color(0xFF10B981);
  static const Color amberWarning = Color(0xFFF59E0B);
  static const Color redDanger = Color(0xFFDC2626);
  static const Color slateText = Color(0xFF64748B);
  static const Color lineBorder = Color(0xFFE2E8F0);
  static const Color background = Color(0xFFF8FAFC);
  static const Color surfaceWhite = Color(0xFFFFFFFF);

  static const Color transparent = Colors.transparent;
  static final Color mutedOnNavy = surfaceWhite.withValues(alpha: 179 / 255);
  static final Color translucentOnNavy = surfaceWhite.withValues(
    alpha: 61 / 255,
  );
  static final Color sidebarSecondaryText = surfaceWhite.withValues(
    alpha: 0.60,
  );
  static final Color sidebarDivider = surfaceWhite.withValues(alpha: 0.12);
  static final Color sidebarSelectionOverlay = surfaceWhite.withValues(
    alpha: 0.10,
  );
  static final Color sidebarActiveSurface = Color.alphaBlend(
    sidebarDivider,
    navy,
  );

  static Color navigationBackdrop(double progress) =>
      navy.withValues(alpha: 0.50 * progress);

  static final Color dialogBackdrop = navy.withValues(alpha: 138 / 255);
  static final Color sectionDialogBackdrop = navy.withValues(alpha: 97 / 255);
  static final Color studentDialogBackdrop = navy.withValues(alpha: 140 / 255);
  static final Color scorebookDialogBackdrop = navy.withValues(alpha: 0.60);
  static final Color studentDialogShadow = navy.withValues(alpha: 128 / 255);

  static final Color subtleCardShadow = navy.withValues(alpha: 0.03);
  static final Color scanCardShadow = navy.withValues(alpha: 0.04);
  static final Color panelShadow = navy.withValues(alpha: 0.05);
  static final Color fieldShadow = navy.withValues(alpha: 0.06);
  static final Color raisedPanelShadow = navy.withValues(alpha: 0.08);
  static final Color importCardShadow = navy.withValues(alpha: 26 / 255);
  static final Color moduleCardShadow = navy.withValues(alpha: 0.12);
  static final Color darkPanelShadow = navy.withValues(alpha: 0.30);

  static final Color cameraInfoOverlay = navy.withValues(alpha: 0.85);
  static final Color cameraControlsOverlay = navy.withValues(alpha: 0.94);
  static final Color cameraFrameOverlay = navy.withValues(alpha: 0.55);
  static final Color cameraFrameBorder = surfaceWhite.withValues(alpha: 0.80);
  static final Color cameraActionBorder = surfaceWhite.withValues(
    alpha: 98 / 255,
  );
  static final Color cameraRetryBorder = surfaceWhite.withValues(
    alpha: 138 / 255,
  );
  static final Color cameraShutterShadow = navy.withValues(alpha: 0.40);

  static final ButtonStyle primaryButtonStyle = FilledButton.styleFrom(
    backgroundColor: navy,
    foregroundColor: surfaceWhite,
    minimumSize: const Size(0, 44),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  );

  static InputDecoration defaultInputDecoration(String hint, IconData icon) {
    final borderRadius = BorderRadius.circular(12);
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: borderRadius,
          borderSide: BorderSide(color: color, width: width),
        );

    return InputDecoration(
      hintText: hint,
      prefixIcon: Icon(icon, color: navy),
      filled: true,
      fillColor: background,
      border: border(lineBorder),
      enabledBorder: border(lineBorder),
      focusedBorder: border(navy, 1.5),
      errorBorder: border(redDanger),
      focusedErrorBorder: border(redDanger, 1.5),
    );
  }

  static SnackBar feedbackSnackBar(
    String message, {
    required Color color,
    Duration duration = const Duration(milliseconds: 4000),
  }) {
    final isError = color == redDanger;
    return SnackBar(
      duration: duration,
      backgroundColor: isError ? surfaceWhite : color,
      content: Text(
        message,
        style: TextStyle(color: isError ? redDanger : navy),
      ),
    );
  }

  static ThemeData get light => ThemeData(
    useMaterial3: true,
    fontFamily: fontFamily,
    scaffoldBackgroundColor: background,
    colorScheme: const ColorScheme.light(
      primary: navy,
      onPrimary: surfaceWhite,
      primaryContainer: navy,
      onPrimaryContainer: surfaceWhite,
      secondary: navy,
      onSecondary: surfaceWhite,
      secondaryContainer: lineBorder,
      onSecondaryContainer: navy,
      tertiary: navy,
      onTertiary: surfaceWhite,
      tertiaryContainer: lineBorder,
      onTertiaryContainer: navy,
      surface: surfaceWhite,
      onSurface: navy,
      onSurfaceVariant: slateText,
      surfaceDim: lineBorder,
      surfaceBright: surfaceWhite,
      surfaceContainerLowest: surfaceWhite,
      surfaceContainerLow: surfaceWhite,
      surfaceContainer: surfaceWhite,
      surfaceContainerHigh: surfaceWhite,
      surfaceContainerHighest: lineBorder,
      surfaceTint: transparent,
      outline: lineBorder,
      outlineVariant: lineBorder,
      error: redDanger,
      onError: surfaceWhite,
      errorContainer: surfaceWhite,
      onErrorContainer: redDanger,
      inverseSurface: navy,
      onInverseSurface: surfaceWhite,
      inversePrimary: surfaceWhite,
      shadow: navy,
      scrim: navy,
    ),
    dividerColor: lineBorder,
    canvasColor: surfaceWhite,
    shadowColor: navy,
    dialogTheme: DialogThemeData(barrierColor: dialogBackdrop),
    bottomSheetTheme: BottomSheetThemeData(modalBarrierColor: dialogBackdrop),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: navy,
        foregroundColor: surfaceWhite,
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: slateText),
    inputDecorationTheme: const InputDecorationThemeData(
      enabledBorder: UnderlineInputBorder(
        borderSide: BorderSide(color: lineBorder),
      ),
      focusedBorder: UnderlineInputBorder(
        borderSide: BorderSide(color: navy, width: 2),
      ),
      errorBorder: UnderlineInputBorder(
        borderSide: BorderSide(color: redDanger),
      ),
      focusedErrorBorder: UnderlineInputBorder(
        borderSide: BorderSide(color: redDanger, width: 2),
      ),
    ),
  );
}
