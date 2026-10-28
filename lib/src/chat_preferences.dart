import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ChatWallpaperPreset { classic, midnight, lavender, paper, plain }

extension ChatWallpaperPresetInfo on ChatWallpaperPreset {
  String get label => switch (this) {
    ChatWallpaperPreset.classic => 'Classic doodles',
    ChatWallpaperPreset.midnight => 'Midnight',
    ChatWallpaperPreset.lavender => 'Lavender',
    ChatWallpaperPreset.paper => 'Paper',
    ChatWallpaperPreset.plain => 'Plain',
  };

  IconData get icon => switch (this) {
    ChatWallpaperPreset.classic => Icons.auto_awesome_outlined,
    ChatWallpaperPreset.midnight => Icons.nightlight_outlined,
    ChatWallpaperPreset.lavender => Icons.gradient_outlined,
    ChatWallpaperPreset.paper => Icons.article_outlined,
    ChatWallpaperPreset.plain => Icons.crop_square_outlined,
  };

  Color background(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return switch (this) {
      ChatWallpaperPreset.classic =>
        dark ? const Color(0xFF0B141A) : const Color(0xFFEFEAE2),
      ChatWallpaperPreset.midnight => const Color(0xFF101827),
      ChatWallpaperPreset.lavender =>
        dark ? const Color(0xFF211E32) : const Color(0xFFF1EEFA),
      ChatWallpaperPreset.paper =>
        dark ? const Color(0xFF25231F) : const Color(0xFFF5F0E8),
      ChatWallpaperPreset.plain => Theme.of(context).scaffoldBackgroundColor,
    };
  }

  bool get hasDoodles => this == ChatWallpaperPreset.classic;
}

class ChatPreferences {
  ChatPreferences(this.preferences) {
    _migrateLegacyDisappearingDefault();
  }

  final SharedPreferences preferences;
  static const _wallpaperPrefix = 'openchat.wallpaper.v2.';
  static const _qualityKey = 'openchat.media_quality.v1';
  static const _dataSaverKey = 'openchat.low_data_mode.v1';
  static const _disappearingPrefix = 'openchat.disappearing.v1.';
  static const _defaultDisappearingKey = 'openchat.privacy.disappearing';

  /// One-shot marker so the legacy account default is wiped exactly once.
  static const _disappearingMigratedKey =
      'openchat.privacy.disappearing.migrated.v2';

  /// Builds before 1.0.1 saved "7 days" (604800) as the account-wide
  /// default even when the user never opened Privacy. Disappearing
  /// messages are opt-in now, so the untouched legacy default is wiped
  /// once; anything the user picks afterwards keeps working.
  void _migrateLegacyDisappearingDefault() {
    if (preferences.getBool(_disappearingMigratedKey) ?? false) return;
    unawaited(_migrateLegacyDefault());
  }

  Future<void> _migrateLegacyDefault() async {
    try {
      if (preferences.getInt(_defaultDisappearingKey) == 604800) {
        await preferences.remove(_defaultDisappearingKey);
      }
      await preferences.setBool(_disappearingMigratedKey, true);
    } catch (_) {
      // Best-effort: the next launch retries, and the effective default
      // stays off either way.
    }
  }

  static const _defaultWallpaperKey = 'openchat.wallpaper.default.v1';

  ChatWallpaperPreset get defaultWallpaper {
    final raw = preferences.getString(_defaultWallpaperKey);
    return ChatWallpaperPreset.values.firstWhere(
      (preset) => preset.name == raw,
      orElse: () => ChatWallpaperPreset.classic,
    );
  }

  Future<void> setDefaultWallpaper(ChatWallpaperPreset preset) =>
      preferences.setString(_defaultWallpaperKey, preset.name);

  ChatWallpaperPreset wallpaperFor(String chatId) {
    final raw = preferences.getString('$_wallpaperPrefix$chatId');
    final found = ChatWallpaperPreset.values
        .where((preset) => preset.name == raw)
        .toList();
    if (found.isNotEmpty) return found.single;
    return defaultWallpaper;
  }

  Future<void> setWallpaper(String chatId, ChatWallpaperPreset preset) {
    return preferences.setString('$_wallpaperPrefix$chatId', preset.name);
  }

  bool get hdMedia => preferences.getString(_qualityKey) != 'standard';

  Future<void> setHdMedia(bool value) =>
      preferences.setString(_qualityKey, value ? 'hd' : 'standard');

  bool get lowDataMode => preferences.getBool(_dataSaverKey) ?? false;

  Future<void> setLowDataMode(bool value) =>
      preferences.setBool(_dataSaverKey, value);

  /// A per-chat override. Zero explicitly disables disappearing messages;
  /// absent values inherit the account default from Privacy settings.
  /// Default is off: messages live forever unless the user opts in,
  /// WhatsApp-style.
  int disappearingSecondsFor(String chatId) =>
      preferences.getInt('$_disappearingPrefix$chatId') ??
      preferences.getInt(_defaultDisappearingKey) ??
      0;

  Future<void> setDisappearingSeconds(String chatId, int seconds) async {
    if (![0, 86400, 604800, 7776000].contains(seconds)) {
      throw ArgumentError('Unsupported disappearing-message timer.');
    }
    await preferences.setInt('$_disappearingPrefix$chatId', seconds);
  }
}

Future<ChatWallpaperPreset?> chooseChatWallpaper(
  BuildContext context,
  ChatWallpaperPreset selected,
) {
  return showModalBottomSheet<ChatWallpaperPreset>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ListTile(
            leading: Icon(Icons.wallpaper_outlined),
            title: Text('Chat wallpaper & theme'),
            subtitle: Text('Personalize this conversation on this device.'),
          ),
          for (final preset in ChatWallpaperPreset.values)
            ListTile(
              leading: Icon(preset.icon),
              title: Text(preset.label),
              trailing: preset == selected
                  ? Icon(
                      Icons.check,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  : null,
              onTap: () => Navigator.pop(context, preset),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
