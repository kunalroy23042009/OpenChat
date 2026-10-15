import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'local_profile.dart';

class AvatarSyncService {
  AvatarSyncService({
    required this.client,
    required this.preferences,
  });

  final SupabaseClient client;
  final SharedPreferences preferences;

  static const _syncStateKey = 'openchat.avatar.sync_state';

  /// Sync state: 'synced', 'pending', 'failed', 'none'
  String get syncState => preferences.getString(_syncStateKey) ?? 'none';

  Future<void> _setSyncState(String state) async {
    await preferences.setString(_syncStateKey, state);
  }

  /// Uploads the current local avatar to Supabase and updates the profile.
  /// Returns true on success, false on failure (local avatar preserved).
  Future<bool> syncCurrentAvatar(LocalProfile profile) async {
    final localPath = profile.avatarPath;
    if (localPath == null || !File(localPath).existsSync()) {
      await _setSyncState('none');
      return true;
    }

    final user = client.auth.currentUser;
    if (user == null) {
      await _setSyncState('pending');
      return false;
    }

    await _setSyncState('pending');

    try {
      final name = '${user.id}/avatar_${DateTime.now().microsecondsSinceEpoch}${p.extension(localPath)}';

      await client.storage.from('avatars').upload(
        name,
        File(localPath),
        fileOptions: const FileOptions(contentType: 'image/jpeg', upsert: true),
      );

      final publicUrl = client.storage.from('avatars').getPublicUrl(name);

      await client.rpc('set_avatar_url', params: {'p_avatar_url': publicUrl});

      await _setSyncState('synced');
      return true;
    } catch (_) {
      await _setSyncState('failed');
      return false;
    }
  }

  /// Removes the avatar from Supabase profile.
  Future<bool> removeAvatar() async {
    final user = client.auth.currentUser;
    if (user == null) return false;

    try {
      await client.rpc('set_avatar_url', params: {'p_avatar_url': null});
      await _setSyncState('none');
      return true;
    } catch (_) {
      await _setSyncState('failed');
      return false;
    }
  }

  /// Call this when the user signs in to sync any pending avatar.
  Future<void> onSignIn(LocalProfile profile) async {
    if (syncState == 'pending' || syncState == 'failed') {
      await syncCurrentAvatar(profile);
    }
  }
}