import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device-local profile: display name, about line, and photo file.
/// The photo stays on this device until media sync lands with messaging.
/// Name/about sync to Supabase through the account RPCs when signed in.
class LocalProfile extends ChangeNotifier {
  LocalProfile(this.preferences) {
    name = preferences.getString(nameKey) ?? '';
    about = preferences.getString(aboutKey) ?? defaultAbout;
    avatarPath = preferences.getString(avatarKey);
    if (avatarPath != null && !File(avatarPath!).existsSync()) {
      avatarPath = null;
    }
  }

  static const nameKey = 'openchat.profile.name';
  static const aboutKey = 'openchat.profile.about';
  static const avatarKey = 'openchat.profile.avatar';
  static const defaultAbout = 'Hey there! I am using Open Chat.';
  static const maxAboutLength = 140;

  final SharedPreferences preferences;
  late String name;
  late String about;
  String? avatarPath;

  File? get avatarFile => avatarPath == null ? null : File(avatarPath!);

  Future<void> save({required String name, required String about}) async {
    final cleanName = name.trim();
    final cleanAbout = about.trim().isEmpty ? defaultAbout : about.trim();
    if (cleanName.isEmpty || cleanName.length > 60) {
      throw ArgumentError('Enter a name of 1–60 characters.');
    }
    if (cleanAbout.length > maxAboutLength) {
      throw ArgumentError('Keep your about line under 140 characters.');
    }
    this.name = cleanName;
    this.about = cleanAbout;
    await preferences.setString(nameKey, cleanName);
    await preferences.setString(aboutKey, cleanAbout);
    notifyListeners();
  }

  /// Copies a picked image into private app storage and remembers it.
  /// Old avatar files are deleted so photos do not accumulate.
  Future<void> setAvatar(String sourcePath) async {
    final dir = await getApplicationDocumentsDirectory();
    final avatars = Directory(p.join(dir.path, 'avatars'));
    if (!await avatars.exists()) {
      await avatars.create(recursive: true);
    }
    final target = File(
      p.join(
        avatars.path,
        'avatar_${DateTime.now().microsecondsSinceEpoch}${p.extension(sourcePath)}',
      ),
    );
    await File(sourcePath).copy(target.path);
    final previous = avatarPath;
    avatarPath = target.path;
    await preferences.setString(avatarKey, target.path);
    notifyListeners();
    if (previous != null && previous != target.path) {
      try {
        await File(previous).delete();
      } catch (_) {
        // Old photo cleanup is best-effort; the new photo is already saved.
      }
    }
  }

  Future<void> removeAvatar() async {
    final previous = avatarPath;
    avatarPath = null;
    await preferences.remove(avatarKey);
    notifyListeners();
    if (previous != null) {
      try {
        await File(previous).delete();
      } catch (_) {
        // Best-effort cleanup.
      }
    }
  }
}
