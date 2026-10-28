import 'dart:html' as html;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device-local profile: display name, about line, and photo file.
/// The photo stays on this device until media sync lands with messaging.
/// Name/about sync to Supabase through the account RPCs when signed in.
class LocalProfile extends ChangeNotifier {
  LocalProfile(this.preferences) {
    name = preferences.getString(nameKey) ?? '';
    about = preferences.getString(aboutKey) ?? defaultAbout;
    _avatarBlob = null;
    final avatarUrl = preferences.getString(avatarKey);
    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      // Load blob from object URL if available
      _avatarObjectUrl = avatarUrl;
    }
  }

  static const nameKey = 'openchat.profile.name';
  static const aboutKey = 'openchat.profile.about';
  static const avatarKey = 'openchat.profile.avatar';
  static const _avatarSyncStateKey = 'openchat.avatar.sync_state';
  static const defaultAbout = 'Hey there! I am using OpenChat.';
  static const maxAboutLength = 140;

  final SharedPreferences preferences;
  late String name;
  late String about;
  String? _avatarObjectUrl;
  html.Blob? _avatarBlob;

  html.Blob? get avatarBlob => _avatarBlob;
  String? get avatarUrl => _avatarObjectUrl;

  File? get avatarFile => null; // Not available on web

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

  /// Sets avatar from a picked file (web: File/Blob from file picker).
  Future<void> setAvatar(html.File file) async {
    final bytes = await _readFileAsBytes(file);
    final blob = html.Blob([bytes], 'image/png');
    
    // Create object URL for display
    if (_avatarObjectUrl != null) {
      html.URL.revokeObjectURL(_avatarObjectUrl!);
    }
    _avatarObjectUrl = html.URL.createObjectUrl(blob);
    _avatarBlob = blob;
    
    await preferences.setString(avatarKey, _avatarObjectUrl!);
    await preferences.setString('openchat.avatar.sync_state', 'pending_upload');
    notifyListeners();
  }

  Future<void> setAvatarFromBlob(html.Blob blob) async {
    if (_avatarObjectUrl != null) {
      html.URL.revokeObjectURL(_avatarObjectUrl!);
    }
    _avatarObjectUrl = html.URL.createObjectUrl(blob);
    _avatarBlob = blob;
    
    await preferences.setString(avatarKey, _avatarObjectUrl!);
    await preferences.setString('openchat.avatar.sync_state', 'pending_upload');
    notifyListeners();
  }

  Future<void> removeAvatar() async {
    if (_avatarObjectUrl != null) {
      html.URL.revokeObjectURL(_avatarObjectUrl!);
      _avatarObjectUrl = null;
    }
    _avatarBlob = null;
    await preferences.remove(avatarKey);
    await preferences.setString('openchat.avatar.sync_state', 'pending_remove');
    notifyListeners();
  }

  Future<Uint8List> _readFileAsBytes(html.File file) async {
    final reader = html.FileReader();
    final completer = Completer<Uint8List>();
    reader.onLoadEnd.listen((_) {
      completer.complete(reader.result as Uint8List);
    });
    reader.readAsArrayBuffer(file);
    return completer.future;
  }
}