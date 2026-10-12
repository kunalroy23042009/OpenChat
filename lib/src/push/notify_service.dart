import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Tap target carried in every notification payload. JSON so the
/// foreground handler, the background isolate, and FCM data messages all
/// share one routing contract.
class NotifyTap {
  const NotifyTap({required this.kind, required this.peer, required this.name});
  final String kind; // 'msg', 'call', or 'status'.
  final String peer;
  final String name;

  String encode() => jsonEncode({'kind': kind, 'peer': peer, 'name': name});

  static NotifyTap? decode(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final map = jsonDecode(payload) as Map<String, dynamic>;
      final kind = map['kind'] as String?;
      final peer = map['peer'] as String?;
      if (kind == null || peer == null) return null;
      if (kind != 'msg' && kind != 'call' && kind != 'status') return null;
      return NotifyTap(
        kind: kind,
        peer: peer,
        name: map['name'] as String? ?? 'Contact',
      );
    } catch (_) {
      return null;
    }
  }
}

/// WhatsApp-style local notifications: message nudges, full-screen call
/// ringing, and status-update alerts. Message bodies and media keys never
/// enter a notification: foreground watchers show the sender name only
/// (decrypting anywhere but the open chat would fork the Signal ratchet),
/// and FCM carries names, never content.
class NotifyService {
  NotifyService._();
  static final NotifyService instance = NotifyService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const messagesChannel = 'openchat_messages';
  static const callsChannel = 'openchat_calls';
  static const statusChannel = 'openchat_status';

  /// Peer ids with a visible chat screen. Messages for these never notify.
  final Set<String> openChats = {};

  /// Foreground tap handler, registered by the home screen (owns navigation).
  Future<void> Function(NotifyTap tap)? onTap;

  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;
    try {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      final ok = await _plugin.initialize(
        settings: const InitializationSettings(android: android),
        onDidReceiveNotificationResponse: (response) {
          final tap = NotifyTap.decode(response.payload);
          if (tap != null) onTap?.call(tap);
        },
      );
      if (ok != true) return;
      final impl = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await impl?.createNotificationChannel(
        const AndroidNotificationChannel(
          messagesChannel,
          'Messages',
          description: 'New encrypted message alerts',
          importance: Importance.high,
        ),
      );
      await impl?.createNotificationChannel(
        const AndroidNotificationChannel(
          callsChannel,
          'Calls',
          description: 'Incoming voice and video call ringing',
          importance: Importance.max,
          playSound: true,
          enableVibration: true,
        ),
      );
      await impl?.createNotificationChannel(
        const AndroidNotificationChannel(
          statusChannel,
          'Status updates',
          description: 'New status updates from contacts',
          importance: Importance.defaultImportance,
        ),
      );
      _ready = true;
    } catch (_) {
      // Plugin unavailable (widget tests, unsupported platforms):
      // every render below degrades to a silent no-op.
      _ready = false;
    }
  }

  /// Runtime notification permission (Android 13+). No-op where unsupported.
  /// Never throws: denial just means silence.
  Future<bool> ensurePermission() async {
    try {
      if (defaultTargetPlatform != TargetPlatform.android) return true;
      final status = await Permission.notification.status;
      if (status.isGranted) return true;
      return (await Permission.notification.request()).isGranted;
    } catch (_) {
      return false;
    }
  }

  /// Pure routing decision, unit-tested: notify for a sender only when no
  /// chat screen for them is visible. Self-messages never notify.
  static bool shouldNotifyMessage({
    required String? myId,
    required String senderId,
    required Set<String> openPeers,
  }) {
    if (senderId.isEmpty) return false;
    if (myId != null && senderId == myId) return false;
    return !openPeers.contains(senderId);
  }

  Future<void> showMessage({
    required String peerId,
    required String name,
  }) async {
    if (!_ready) return;
    if (!shouldNotifyMessage(
      myId: null,
      senderId: peerId,
      openPeers: openChats,
    )) {
      return;
    }
    await _plugin.show(
      id: peerId.hashCode & 0x7fffffff,
      title: name,
      body: 'New message',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          messagesChannel,
          'Messages',
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.message,
        ),
      ),
      payload: NotifyTap(kind: 'msg', peer: peerId, name: name).encode(),
    );
  }

  /// Full-screen ringing that opens the app onto the incoming-call dialog.
  Future<void> showCall({
    required String inviteId,
    required String name,
    required bool video,
  }) async {
    if (!_ready) return;
    await _plugin.show(
      id: inviteId.hashCode & 0x7fffffff,
      title: 'Incoming ${video ? 'video' : 'voice'} call',
      body: name,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          callsChannel,
          'Calls',
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.call,
          fullScreenIntent: true,
          ongoing: true,
          autoCancel: false,
        ),
      ),
      payload: NotifyTap(kind: 'call', peer: inviteId, name: name).encode(),
    );
  }

  Future<void> cancelCall(String inviteId) {
    if (!_ready) return Future.value();
    return _plugin.cancel(id: inviteId.hashCode & 0x7fffffff);
  }

  Future<void> showStatus({
    required String authorId,
    required String name,
    required String snippet,
  }) async {
    if (!_ready) return;
    await _plugin.show(
      id: authorId.hashCode & 0x7fffffff,
      title: '$name posted a status',
      body: snippet.isEmpty ? 'Tap to view' : snippet,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          statusChannel,
          'Status updates',
          category: AndroidNotificationCategory.status,
        ),
      ),
      payload: NotifyTap(kind: 'status', peer: authorId, name: name).encode(),
    );
  }

  Future<void> cancelChat(String peerId) {
    if (!_ready) return Future.value();
    return _plugin.cancel(id: peerId.hashCode & 0x7fffffff);
  }

  /// Best-effort poke after a user-visible send so a killed/background peer
  /// still rings via FCM. Foreground peers are covered by their realtime
  /// watcher (FCM onMessage stays silent), so this never double-notifies.
  /// Never throws and never blocks the send path.
  static Future<void> poke(
    SupabaseClient client, {
    required String kind,
    String? peer,
    String? invite,
    bool video = false,
  }) async {
    try {
      await client.functions
          .invoke(
            'notify-send',
            body: {
              'kind': kind,
              'peer': ?peer,
              'invite': ?invite,
              if (video) 'video': true,
            },
          )
          .timeout(const Duration(seconds: 8));
    } catch (_) {}
  }
}
