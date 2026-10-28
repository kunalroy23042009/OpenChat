import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'local_profile.dart';

class AvatarSyncService {
  AvatarSyncService({required this.client, required this.preferences});

  final SupabaseClient client;
  final SharedPreferences preferences;

  static const _syncStateKey = 'openchat.avatar.sync_state';

  /// Sync state: 'synced_private', 'pending_upload', 'pending_remove',
  /// 'failed', or 'none'.
  String get syncState => preferences.getString(_syncStateKey) ?? 'none';

  Future<void> _setSyncState(String state) async {
    await preferences.setString(_syncStateKey, state);
  }

  Future<void> markPendingUpload() => _setSyncState('pending_upload');

  Future<void> markPendingRemoval() => _setSyncState('pending_remove');

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
      await _setSyncState('pending_upload');
      return false;
    }

    await _setSyncState('pending_upload');

    try {
      final extension = p.extension(localPath).toLowerCase();
      final name =
          '${user.id}/avatar_${DateTime.now().microsecondsSinceEpoch}$extension';

      await client.storage
          .from('profile-avatars')
          .upload(
            name,
            File(localPath),
            fileOptions: FileOptions(
              contentType: extension == '.png' ? 'image/png' : 'image/jpeg',
              upsert: true,
            ),
          );

      await client.rpc('set_profile_avatar', params: {'p_path': name});

      await _setSyncState('synced_private');
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
      await client.rpc('set_profile_avatar', params: {'p_path': null});
      await _setSyncState('none');
      return true;
    } catch (_) {
      await _setSyncState('pending_remove');
      return false;
    }
  }

  /// Call this when the user signs in to sync any pending avatar.
  Future<void> onSignIn(LocalProfile profile) async {
    if (syncState == 'pending_remove') {
      await removeAvatar();
    } else if (profile.avatarPath != null && syncState != 'synced_private') {
      await syncCurrentAvatar(profile);
    }
  }
}
