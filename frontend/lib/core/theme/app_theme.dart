import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  // ─────────────────────────────────────────────
  // MY EYES COLOR SYSTEM
  // ─────────────────────────────────────────────

  static const Color background = Color(0xFF070A12);
  static const Color surface = Color(0xFF101522);
  static const Color surfaceLight = Color(0xFF171D2D);

  static const Color primary = Color(0xFF6C63FF);
  static const Color primaryLight = Color(0xFF8B85FF);

  static const Color accent = Color(0xFF42D9FF);

  static const Color textPrimary = Color(0xFFF7F8FC);
  static const Color textSecondary = Color(0xFFA9B0C3);

  static const Color success = Color(0xFF42D392);
  static const Color error = Color(0xFFFF647C);

  // ─────────────────────────────────────────────
  // DARK THEME
  // ─────────────────────────────────────────────

  static ThemeData darkTheme = ThemeData(
    brightness: Brightness.dark,

    scaffoldBackgroundColor: background,

    colorScheme: const ColorScheme.dark(
      primary: primary,
      secondary: accent,
      surface: surface,
      error: error,
    ),

    fontFamily: 'sans-serif',

    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
      foregroundColor: textPrimary,
    ),

    textTheme: const TextTheme(
      displayLarge: TextStyle(
        color: textPrimary,
        fontSize: 42,
        fontWeight: FontWeight.w700,
        letterSpacing: -1.2,
      ),

      displayMedium: TextStyle(
        color: textPrimary,
        fontSize: 34,
        fontWeight: FontWeight.w700,
      ),

      headlineLarge: TextStyle(
        color: textPrimary,
        fontSize: 28,
        fontWeight: FontWeight.w700,
      ),

      headlineMedium: TextStyle(
        color: textPrimary,
        fontSize: 24,
        fontWeight: FontWeight.w600,
      ),

      titleLarge: TextStyle(
        color: textPrimary,
        fontSize: 20,
        fontWeight: FontWeight.w600,
      ),

      bodyLarge: TextStyle(
        color: textPrimary,
        fontSize: 17,
        height: 1.5,
      ),

      bodyMedium: TextStyle(
        color: textSecondary,
        fontSize: 15,
        height: 1.5,
      ),
    ),

    useMaterial3: true,
  );
}