import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'notify_service.dart';

/// Background messages must be handled in a top-level function.
/// Data-only nudges from the notify-send Edge Function render here via the
/// same local-notification stack as the foreground watchers. Payloads carry
/// routing ids and display names only — never message content or keys.
@pragma('vm:entry-point')
Future<void> pushBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
  } catch (e) {
    debugPrint('FCM BG: Firebase init failed: $e');
    return;
  }
  try {
    await NotifyService.instance.init();
    debugPrint('FCM BG: NotifyService initialized');
    await renderPushMessage(message, background: true);
    debugPrint('FCM BG: renderPushMessage completed');
  } catch (e, st) {
    debugPrint('FCM BG: error: $e\n$st');
  }
}

Future<void> renderPushMessage(
  RemoteMessage message, {
  bool background = false,
}) async {
  try {
    final data = message.data;
    switch (data['kind']) {
      case 'message':
        final peer = data['peer'] as String? ?? '';
        if (peer.isEmpty) return;
        await NotifyService.instance.showMessage(
          peerId: peer,
          name: _orContact(data['name'] as String?),
          event: data['event'] as String?,
          ignoreOpenChats: background,
        );
      case 'call':
        final invite = data['invite'] as String? ?? '';
        if (invite.isEmpty) return;
        await NotifyService.instance.showCall(
          inviteId: invite,
          name: _orContact(data['name'] as String?),
          video: data['video'] == 'true',
        );
      case 'status':
        final author = data['peer'] as String? ?? '';
        if (author.isEmpty) return;
        await NotifyService.instance.showStatus(
          authorId: author,
          name: _orContact(data['name'] as String?),
          snippet: data['snippet'] as String? ?? '',
          event: data['event'] as String?,
        );
    }
  } catch (_) {
    // A failed background render must never crash the isolate.
  }
}

String _orContact(String? name) =>
    (name == null || name.trim().isEmpty) ? 'New contact' : name;

enum PushState { disabled, ready, denied }

/// Owns Firebase messaging: permission, token lifecycle, and server upload.
/// Server sends only generic new-message nudges; message content and keys
/// never travel through push. Never throws: failures resolve to [PushState.disabled].
class PushService {
  PushService({this._messaging});

  final FirebaseMessaging? _messaging;
  StreamSubscription<String>? _refreshSubscription;
  StreamSubscription<RemoteMessage>? _foregroundSubscription;
  PushState state = PushState.disabled;
  String? lastError;

  Future<PushState> initialize(SupabaseClient? client) async {
    debugPrint('PushService: initialize() called');
    if (kIsWeb) {
      debugPrint('PushService: Web platform, disabling');
      state = PushState.disabled;
      return state;
    }
    try {
      debugPrint('PushService: Firebase.initializeApp()');
      await Firebase.initializeApp();
      debugPrint('PushService: Firebase initialized');
      final messaging = _messaging ?? FirebaseMessaging.instance;
      final settings = await messaging.requestPermission();
      debugPrint('PushService: permission status=\${settings.authorizationStatus}');
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        state = PushState.denied;
        return state;
      }
      FirebaseMessaging.onBackgroundMessage(pushBackgroundHandler);
      debugPrint('PushService: calling NotifyService.init()');
      await NotifyService.instance.init();
      debugPrint('PushService: NotifyService.init() done');
      await _foregroundSubscription?.cancel();
      _foregroundSubscription = FirebaseMessaging.onMessage.listen((message) {
        final recipient = message.data['recipient'];
        if (client?.auth.currentUser?.id == recipient) {
          unawaited(renderPushMessage(message));
        }
      });
final userId = client?.auth.currentUser?.id;
      debugPrint('PushService: userId=$userId');
      // For testing: register token even without user (dev only)
      await _upload(messaging, client!);
      // if (userId != null) {
      //   await _upload(messaging, client!);
      // }
      await _refreshSubscription?.cancel();
      _refreshSubscription = messaging.onTokenRefresh.listen((_) async {
        final current = client?.auth.currentUser?.id;
        if (current != null) {
          await _upload(messaging, client!);
        }
      });
      state = PushState.ready;
      debugPrint('PushService: ready');
    } catch (e, st) {
      debugPrint('PushService: initialize error: \$e\n\$st');
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
    debugPrint('PushService: FCM token = $token');
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
      debugPrint('PushService: token uploaded successfully');
    } catch (_) {
      debugPrint('PushService: token upload failed');
    }
  }

  Future<void> dispose() async {
    await _refreshSubscription?.cancel();
    await _foregroundSubscription?.cancel();
  }
}
