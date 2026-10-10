import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppThemeMode {
  system,
  light,
  dark,
  emerald,
}

class AppThemeController extends ValueNotifier<AppThemeMode> {
  AppThemeController(this._prefs)
      : super(_parseTheme(_prefs.getString(_prefKey)));

  final SharedPreferences _prefs;
  static const String _prefKey = 'openchat.theme_mode.v1';

  static AppThemeMode _parseTheme(String? value) {
    switch (value) {
      case 'light':
        return AppThemeMode.light;
      case 'dark':
        return AppThemeMode.dark;
      case 'emerald':
        return AppThemeMode.emerald;
      case 'system':
      default:
        return AppThemeMode.system;
    }
  }

  void setTheme(AppThemeMode mode) {
    value = mode;
    _prefs.setString(_prefKey, mode.name);
  }

  ThemeData get lightTheme => ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF245CDB),
          primary: const Color(0xFF245CDB),
          surface: const Color(0xFFF8FAFD),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF8FAFD),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF8FAFD),
          foregroundColor: Color(0xFF22334E),
          elevation: 0,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFEDF1F7),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
        ),
      );

  ThemeData get darkTheme => ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3B82F6),
          primary: const Color(0xFF3B82F6),
          surface: const Color(0xFF0F172A),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0F172A),
          foregroundColor: Color(0xFFF8FAFC),
          elevation: 0,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF1E293B),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
        ),
      );

  ThemeData get emeraldTheme => ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF10B981),
          primary: const Color(0xFF10B981),
          surface: const Color(0xFF064E3B),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF064E3B),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF064E3B),
          foregroundColor: Color(0xFFECFDF5),
          elevation: 0,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF047857),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
        ),
      );

  ThemeData get activeTheme {
    switch (value) {
      case AppThemeMode.light:
        return lightTheme;
      case AppThemeMode.dark:
        return darkTheme;
      case AppThemeMode.emerald:
        return emeraldTheme;
      case AppThemeMode.system:
        return lightTheme;
    }
  }

  ThemeMode get themeMode {
    switch (value) {
      case AppThemeMode.light:
        return ThemeMode.light;
      case AppThemeMode.dark:
      case AppThemeMode.emerald:
        return ThemeMode.dark;
      case AppThemeMode.system:
        return ThemeMode.system;
    }
  }
}
