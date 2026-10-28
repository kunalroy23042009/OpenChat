import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../ops/error_report.dart';

/// Real-time profile directory: watches `profiles` changes over Supabase
/// realtime so avatar/name changes propagate app-wide within seconds —
/// WhatsApp-style. Row visibility rides the server's RLS policies
/// (photo/last-seen audience), so blocked or out-of-audience users never
/// receive the events at all.
///
/// Also keeps a short-TTL signed-URL cache [avatarUrlFor] keyed by the
/// profile's avatar path, so list rows don't re-sign the same object on
/// every rebuild — but avatar changes get fresh URLs immediately.
///
/// Facts resolved on profile changes (name/photo state) live on the
/// [resolve] snapshots so widgets can re-render online/last-seen text.
class ProfileWatcher extends ChangeNotifier {
  ProfileWatcher._(this._client);

  SupabaseClient _client;
  RealtimeChannel? _channel;
  Timer? _debounce;
  Map<String, Map<String, dynamic>> _profiles = {};

  /// avatar path -> (signedUrl, resolvedAt)
  final Map<String, ({String url, DateTime at})> _urlCache = {};
  static const _signedUrlTtl = Duration(minutes: 55);

  /// Revision bumps whenever a watched profile row changed; widgets listen.
  int get revision => _revision;
  int _revision = 0;

  static final Map<String, ProfileWatcher> _instances = {};

  /// One watcher per process (home and screens share it).
  static ProfileWatcher of(SupabaseClient client) {
    final existing = _instances['primary'];
    if (existing != null) {
      existing._client = client;
      return existing;
    }
    final watcher = ProfileWatcher._(client);
    _instances['primary'] = watcher;
    return watcher;
  }

  /// Latest known facts for a profile id (from realtime events).
  Map<String, dynamic>? factsFor(String userId) => _profiles[userId];

  /// Begins watching. Safe to call repeatedly (channels are replaced only
  /// when the signed-in user changes).
  void start() {
    final uid = _client.auth.currentUser?.id;
    if (uid == null) {
      stop();
      return;
    }
    if (_channel != null) return;
    _channel = _client
        .channel('profiles-live-$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'profile_changes',
          callback: (payload) {
            final row = payload.newRecord;
            final id = row['id']?.toString();
            if (id == null) return;
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 300), () {
              _profiles.clear();
              _urlCache.clear();
              _revision += 1;
              notifyListeners();
            });
          },
        );
    _channel!.subscribe();
    unawaited(_refreshSelf());
  }

  void stop() {
    _debounce?.cancel();
    _debounce = null;
    final channel = _channel;
    _channel = null;
    _profiles = {};
    _urlCache.clear();
    if (channel != null) {
      try {
        unawaited(_client.removeChannel(channel));
      } catch (_) {}
    }
  }

  void _applyRow(String id, Map<String, dynamic> row) {
    final previous = _profiles[id];
    // Invalidate the signed-URL cache only when the photo actually changed.
    if (previous != null && previous['avatar_path'] != row['avatar_path']) {
      _urlCache.remove(previous['avatar_path']);
      _urlCache.remove(row['avatar_path']);
    }
    _profiles[id] = {
      'display_name': row['display_name'] as String?,
      'avatar_path': row['avatar_path'] as String?,
      'is_online': row['is_online'] as bool?,
      'last_seen': row['last_seen'] as String?,
    };
  }

  /// Signed avatar URL for a profile row's avatar path, with the public
  /// legacy URL as fallback. Cached ~55 minutes per path.
  Future<String?> avatarUrlFor(String? avatarPath, String? legacyUrl) async {
    if (avatarPath == null || avatarPath.isEmpty) return legacyUrl;
    final cached = _urlCache[avatarPath];
    if (cached != null &&
        DateTime.now().difference(cached.at) < _signedUrlTtl) {
      return cached.url;
    }
    try {
      final url = await _client.storage
          .from('profile-avatars')
          .createSignedUrl(avatarPath, 60 * 60);
      _urlCache[avatarPath] = (url: url, at: DateTime.now());
      return url;
    } catch (e) {
      ErrorReport.reportError('avatar-url', e, code: 'sign_failed');
      return legacyUrl;
    }
  }

  /// Bell for the signed-in user's own row (used by the app-wide avatar).
  Future<void> _refreshSelf() async {
    final uid = _client.auth.currentUser?.id;
    if (uid == null) return;
    try {
      final row = await _client
          .from('profiles')
          .select('display_name, avatar_path, is_online, last_seen')
          .eq('id', uid)
          .maybeSingle();
      if (row != null) {
        _applyRow(uid, Map<String, dynamic>.from(row));
        _revision += 1;
        notifyListeners();
      }
    } catch (e) {
      ErrorReport.reportError('profiles-watch', e, code: 'self_fetch');
    }
  }
}
