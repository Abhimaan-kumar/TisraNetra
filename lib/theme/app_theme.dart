import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Percive Premium Dark Theme
/// Centralized design tokens – UI only, zero functional changes.
class AppTheme {
  AppTheme._();

  // ── Palette ──────────────────────────────────────────────────────────────
  static const Color bg          = Color(0xFF0B0F1A);
  static const Color splashbg    = Color(0xFFe4e6e7);
  static const Color surface     = Color(0xFF141929);
  static const Color card        = Color(0xFF1C2137);
  static const Color cardBorder  = Color(0xFF2A3050);
  static const Color accent      = Color(0xFF7B6EF6); // vibrant purple
  static const Color accentLight = Color(0xFFA99FFE);
  static const Color cyan        = Color(0xFF00E5FF);
  static const Color green       = Color(0xFF00E676);
  static const Color orange      = Color(0xFFFF9100);
  static const Color red         = Color(0xFFFF3D71);
  static const Color textPrimary = Color(0xFFF0F0F5);
  static const Color textSecondary = Color(0xFF8E8EA0);
  static const Color divider     = Color(0xFF252B45);

  // ── Gradients ────────────────────────────────────────────────────────────
  static const LinearGradient bgGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF0B0F1A), Color(0xFF111830)],
  );

  static const LinearGradient accentGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF7B6EF6), Color(0xFF5B4AE4)],
  );

  static const LinearGradient cyanGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF00E5FF), Color(0xFF006BFF)],
  );

  // ── Card gradients for menu items ──────────────────────────────────────
  static const List<List<Color>> cardGradients = [
    [Color(0xFF1DB9A0), Color(0xFF0E7D6D)],  // Read Anything - teal
    [Color(0xFF9B59B6), Color(0xFF6C3483)],  // Currency - purple
    [Color(0xFF3F51B5), Color(0xFF283593)],  // Navigate - indigo
    [Color(0xFF27AE60), Color(0xFF1E8449)],  // Object Recognition - green
    [Color(0xFF16A085), Color(0xFF0E6655)],  // Scene Captioning - dark teal
    [Color(0xFFD4AC0D), Color(0xFFB7950B)],  // Person ID - gold
    [Color(0xFF2980B9), Color(0xFF1A5276)],  // Color - blue
    [Color(0xFFCA6F1E), Color(0xFF935116)],  // Volunteer - copper
    [Color(0xFF7D8C2E), Color(0xFF566420)],  // AI Buddy - olive
    [Color(0xFFCB4335), Color(0xFF922B21)],  // Emergency - red
  ];

  // ── Border Radius ────────────────────────────────────────────────────────
  static const double radiusSm  = 12;
  static const double radiusMd  = 16;
  static const double radiusLg  = 24;
  static const double radiusXl  = 32;

  // ── Theme Data ───────────────────────────────────────────────────────────
  static ThemeData get darkTheme {
    final base = ThemeData.dark();
    return base.copyWith(
      scaffoldBackgroundColor: splashbg,
      colorScheme: ColorScheme.dark(
        primary: accent,
        secondary: cyan,
        surface: surface,
        error: red,
        onPrimary: Colors.white,
        onSecondary: Colors.black,
        onSurface: textPrimary,
        onError: Colors.white,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        iconTheme: const IconThemeData(color: textPrimary),
        titleTextStyle: GoogleFonts.inter(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: textPrimary,
        ),
      ),
      cardTheme: CardThemeData(
        color: card,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          side: const BorderSide(color: cardBorder, width: 1),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          elevation: 0,
          textStyle: GoogleFonts.inter(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMd),
          ),
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: accent,
          side: const BorderSide(color: accent, width: 1.5),
          textStyle: GoogleFonts.inter(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMd),
          ),
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accent,
          textStyle: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        hintStyle: GoogleFonts.inter(color: textSecondary),
        labelStyle: GoogleFonts.inter(color: textSecondary),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: const BorderSide(color: cardBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: const BorderSide(color: cardBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: const BorderSide(color: accent, width: 1.5),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: const BorderSide(color: divider),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: const BorderSide(color: red),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surface,
        labelStyle: GoogleFonts.inter(color: textPrimary, fontSize: 12),
        side: const BorderSide(color: cardBorder),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSm),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: card,
        contentTextStyle: GoogleFonts.inter(color: textPrimary),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSm),
        ),
        behavior: SnackBarBehavior.floating,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLg),
        ),
        titleTextStyle: GoogleFonts.inter(
          color: textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
        contentTextStyle: GoogleFonts.inter(
          color: textSecondary,
          fontSize: 14,
        ),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        textStyle: GoogleFonts.inter(color: textPrimary),
      ),
      textTheme: GoogleFonts.interTextTheme(base.textTheme).apply(
        bodyColor: textPrimary,
        displayColor: textPrimary,
      ),
      dividerColor: divider,
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: accent,
      ),
    );
  }

  // ── Glassmorphic box decoration ────────────────────────────────────────
  static BoxDecoration get glassCard => BoxDecoration(
    color: card.withOpacity(0.6),
    borderRadius: BorderRadius.circular(radiusMd),
    border: Border.all(color: cardBorder.withOpacity(0.5), width: 1),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withOpacity(0.2),
        blurRadius: 20,
        offset: const Offset(0, 8),
      ),
    ],
  );

  // ── Helper: accent glow shadow ─────────────────────────────────────────
  static List<BoxShadow> glowShadow(Color color, {double blur = 20}) => [
    BoxShadow(
      color: color.withOpacity(0.3),
      blurRadius: blur,
      spreadRadius: 1,
    ),
  ];
}
