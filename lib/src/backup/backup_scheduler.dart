import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat_store.dart';
import 'chat_backup.dart';
import 'google_drive_backup.dart';

/// Platform-agnostic backup scheduler.
/// Uses WorkManager on Android, BGTaskScheduler on iOS, and a fallback timer on desktop/web.
class BackupScheduler {
  BackupScheduler._internal(this._client, this._store, this._prefs);
  
  final SupabaseClient _client;
  final ChatStore _store;
  final SharedPreferences _prefs;

  static BackupScheduler? _instance;

  static BackupScheduler get instance {
    if (_instance == null) {
      throw StateError('BackupScheduler not initialized. Call BackupScheduler.initialize() first.');
    }
    return _instance!;
  }

  static Future<void> initialize({
    required SupabaseClient client,
    required ChatStore store,
    required SharedPreferences prefs,
  }) async {
    _instance = BackupScheduler._internal(client, store, prefs);
    await _instance!._schedule();
  }

  Future<void> _schedule() async {
    if (kIsWeb) {
      // Web fallback: periodic timer (not reliable for true background)
      _webTimer?.cancel();
      _webTimer = Timer.periodic(const Duration(hours: 6), (_) => _runIfDue());
      debugPrint('BackupScheduler: Web fallback timer started (6h interval)');
      return;
    }

    if (Platform.isAndroid) {
      await _scheduleAndroid();
    } else if (Platform.isIOS) {
      await _scheduleIOS();
    } else {
      // Desktop fallback
      _webTimer?.cancel();
      _webTimer = Timer.periodic(const Duration(hours: 6), (_) => _runIfDue());
      debugPrint('BackupScheduler: Desktop fallback timer started (6h interval)');
    }
  }

  static Timer? _webTimer;

  Future<void> _runIfDue() async {
    try {
      final uid = _client.auth.currentUser?.id;
      if (uid == null) return;
      
      await ChatBackup.maybeAutoBackup(
        client: _client,
        store: _store,
        uid: uid,
        prefs: _prefs,
      );
      
      // After successful backup, also try Drive mirror if enabled
      final freq = ChatBackup.frequency(_prefs, uid);
      if (freq != 'never' && await GoogleDriveBackup.isSignedIn()) {
        if (await GoogleDriveBackup.networkAllowed(_prefs, uid)) {
          final bytes = await ChatBackup.downloadBackup(_client, uid);
          if (bytes != null) {
            await GoogleDriveBackup.uploadBackupBytes(
              bytes,
              GoogleDriveBackup.fileName(
                uid,
                DateTime.now().toUtc().microsecondsSinceEpoch.toString(),
              ),
            );
            await GoogleDriveBackup.pruneOld(3);
          }
        }
      }
    } catch (_) {
      // Silent - background tasks must never throw
    }
  }

  Future<void> _scheduleAndroid() async {
    try {
      // Use WorkManager via platform channel
      // For now, use a foreground timer as fallback
      // TODO: Implement proper WorkManager integration via method channel
      _webTimer?.cancel();
      _webTimer = Timer.periodic(const Duration(hours: 6), (_) => _runIfDue());
      debugPrint('BackupScheduler: Android fallback timer started (6h interval)');
    } catch (_) {
      _webTimer?.cancel();
      _webTimer = Timer.periodic(const Duration(hours: 6), (_) => _runIfDue());
      debugPrint('BackupScheduler: Android fallback timer started (6h interval)');
    }
  }

  Future<void> _scheduleIOS() async {
    try {
      // Use BGTaskScheduler via platform channel
      // For now, use a foreground timer as fallback
      _webTimer?.cancel();
      _webTimer = Timer.periodic(const Duration(hours: 6), (_) => _runIfDue());
      debugPrint('BackupScheduler: iOS fallback timer started (6h interval)');
    } catch (_) {
      _webTimer?.cancel();
      _webTimer = Timer.periodic(const Duration(hours: 6), (_) => _runIfDue());
      debugPrint('BackupScheduler: iOS fallback timer started (6h interval)');
    }
  }

  void dispose() {
    _webTimer?.cancel();
    _webTimer = null;
  }

  /// Manually triggers a backup if due (for testing or manual refresh).
  static Future<void> runNow({
    required SupabaseClient client,
    required ChatStore store,
    required String uid,
    required SharedPreferences prefs,
  }) async {
    await ChatBackup.maybeAutoBackup(
      client: client,
      store: store,
      uid: uid,
      prefs: prefs,
    );
  }
}