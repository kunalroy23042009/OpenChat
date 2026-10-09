import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Background messages must be handled in a top-level function.
/// Pilot behavior: wake the plugin; payload handling lands with messaging.
@pragma('vm:entry-point')
Future<void> pushBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
  } catch (_) {
    // A failed background init must never crash the isolate.
  }
}

enum PushState { disabled, ready, denied }

/// Owns Firebase messaging: permission, token lifecycle, and server upload.
/// Server sends only generic new-message nudges; message content and keys
/// never travel through push. Never throws: failures resolve to [PushState.disabled].
class PushService {
  PushService({this._messaging});

  final FirebaseMessaging? _messaging;
  StreamSubscription<String>? _refreshSubscription;
  PushState state = PushState.disabled;
  String? lastError;

  Future<PushState> initialize(SupabaseClient? client) async {
    if (kIsWeb) {
      // Web push needs a VAPID key and its own assessment; out of pilot scope.
      state = PushState.disabled;
      return state;
    }
    try {
      await Firebase.initializeApp();
      final messaging = _messaging ?? FirebaseMessaging.instance;
      final settings = await messaging.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        state = PushState.denied;
        return state;
      }
      FirebaseMessaging.onBackgroundMessage(pushBackgroundHandler);
      final userId = client?.auth.currentUser?.id;
      if (userId != null) {
        await _upload(messaging, client!);
      }
      await _refreshSubscription?.cancel();
      _refreshSubscription = messaging.onTokenRefresh.listen((_) async {
        final current = client?.auth.currentUser?.id;
        if (current != null) {
          await _upload(messaging, client!);
        }
      });
      state = PushState.ready;
    } catch (_) {
      // Missing google-services setup, no Play services, or any plugin
      // failure: push stays off and the rest of the app keeps working.
      state = PushState.disabled;
    }
    return state;
  }

  /// Re-upload after sign-in, since startup may precede authentication.
  Future<void> syncAccount(SupabaseClient client) async {
    if (state != PushState.ready) return;
    try {
      await _upload(_messaging ?? FirebaseMessaging.instance, client);
    } catch (_) {
      lastError = 'Push token sync failed. It will retry on restart.';
    }
  }

  Future<void> _upload(
    FirebaseMessaging messaging,
    SupabaseClient client,
  ) async {
    final token = await messaging.getToken();
    if (token == null || token.length < 32) return;
    try {
      await client.rpc(
        'register_push_token',
        params: {
          'p_token': token,
          'p_platform': defaultTargetPlatform == TargetPlatform.iOS
              ? 'ios'
              : 'android',
        },
      );
    } catch (_) {
      // Quota, validation, or connectivity failure: keep the token locally
      // and retry on next start. Never surface token material in errors.
      lastError = 'Push registration failed. It will retry on restart.';
    }
  }

  Future<void> dispose() async {
    await _refreshSubscription?.cancel();
  }
}
