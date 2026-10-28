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
  const NotifyTap({
    required this.kind,
    required this.peer,
    required this.name,
    this.action,
  });
  final String kind; // 'msg', 'group', 'call', or 'status'.
  final String peer;
  final String name;
  final String? action;

  /// Actions come from the platform response, never from a sender's payload.
  static NotifyTap? fromResponse(NotificationResponse? response) {
    final tap = decode(response?.payload);
    if (tap == null) return null;
    return NotifyTap(
      kind: tap.kind,
      peer: tap.peer,
      name: tap.name,
      action: response?.actionId == 'reply' ? 'reply' : null,
    );
  }

  String encode() => jsonEncode({'kind': kind, 'peer': peer, 'name': name});

  static NotifyTap? decode(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final map = jsonDecode(payload) as Map<String, dynamic>;
      final kind = map['kind'] as String?;
      final peer = map['peer'] as String?;
      if (kind == null || peer == null) return null;
      if (kind != 'msg' &&
          kind != 'group' &&
          kind != 'call' &&
          kind != 'missed_call' &&
          kind != 'status') {
        return null;
      }
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
  static const silentMessagesChannel = 'openchat_messages_silent';
  static const callsChannel = 'openchat_calls';
  static const statusChannel = 'openchat_status';
  static const groupsChannel = 'openchat_groups';

  /// Peer ids with a visible chat screen. Messages for these never notify.
  final Set<String> openChats = {};
  final Set<String> openGroups = {};

  /// Foreground tap handler, registered by the home screen (owns navigation).
  Future<void> Function(NotifyTap tap)? onTap;

  bool _ready = false;
  final Set<String> _shownEvents = {};

  /// Stable across background isolates and process restarts; types occupy
  /// separate namespaces so a status cannot replace a chat notification.
  static int notificationId(String kind, String id) {
    var hash = 2166136261;
    for (final unit in '$kind:$id'.codeUnits) {
      hash = ((hash ^ unit) * 16777619) & 0x7fffffff;
    }
    return hash;
  }

  Future<NotifyTap?> launchTap() async {
    if (!_ready) return null;
    try {
      final launch = await _plugin.getNotificationAppLaunchDetails();
      return launch?.didNotificationLaunchApp == true
          ? NotifyTap.fromResponse(launch?.notificationResponse)
          : null;
    } catch (_) {
      return null;
    }
  }

  bool _newEvent(String kind, String? event) {
    if (event == null) return true;
    if (!_shownEvents.add('$kind:$event')) return false;
    if (_shownEvents.length > 500) _shownEvents.remove(_shownEvents.first);
    return true;
  }

  Future<void> init() async {
    if (_ready) return;
    try {
      debugPrint('NotifyService: initializing...');
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      final ok = await _plugin.initialize(
        settings: const InitializationSettings(android: android),
        onDidReceiveNotificationResponse: (response) {
          final tap = NotifyTap.fromResponse(response);
          if (tap != null) onTap?.call(tap);
        },
      );
      debugPrint('NotifyService: plugin initialized ok=$ok');
      if (ok != true) return;
      final impl = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      debugPrint('NotifyService: android impl = $impl');
      if (impl == null) {
        debugPrint('NotifyService: ERROR - Android impl is null!');
        return;
      }
      await impl.createNotificationChannel(
        const AndroidNotificationChannel(
          messagesChannel,
          'Messages',
          description: 'New encrypted message alerts',
          importance: Importance.max,
        ),
      );
      debugPrint('NotifyService: messages channel created');
      await impl.createNotificationChannel(
        const AndroidNotificationChannel(
          silentMessagesChannel,
          'Silent messages',
          description: 'Muted and no-tone message alerts',
          importance: Importance.low,
          playSound: false,
          enableVibration: false,
        ),
      );
      await impl.createNotificationChannel(
        const AndroidNotificationChannel(
          callsChannel,
          'Calls',
          description: 'Incoming voice and video call ringing',
          importance: Importance.max,
          playSound: true,
          enableVibration: true,
        ),
      );
      debugPrint('NotifyService: calls channel created');
      await impl.createNotificationChannel(
        const AndroidNotificationChannel(
          statusChannel,
          'Status updates',
          description: 'New status updates from contacts',
          importance: Importance.max,
        ),
      );
      debugPrint('NotifyService: status channel created');
      await impl.createNotificationChannel(
        const AndroidNotificationChannel(
          groupsChannel,
          'Group messages',
          description: 'New group message alerts',
          importance: Importance.max,
          playSound: true,
          enableVibration: true,
        ),
      );
      debugPrint('NotifyService: groups channel created');
      _ready = true;
      debugPrint('NotifyService: ready=$_ready');
    } catch (e, st) {
      debugPrint('NotifyService: init error: $e\n$st');
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
    String? event,
    bool ignoreOpenChats = false,
    bool silent = false,
  }) async {
    if (!_ready) {
      debugPrint('NotifyService: showMessage - not ready');
      return;
    }
    if (!ignoreOpenChats &&
        !shouldNotifyMessage(
          myId: null,
          senderId: peerId,
          openPeers: openChats,
        )) {
      debugPrint(
        'NotifyService: showMessage - suppressed by shouldNotifyMessage',
      );
      return;
    }
    if (!_newEvent('msg', event)) {
      debugPrint('NotifyService: showMessage - deduplicated');
      return;
    }
    debugPrint('NotifyService: showing message for peer=$peerId name=$name');
    await _plugin.show(
      id: notificationId('msg', peerId),
      title: name,
      body: 'New message',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          silent ? silentMessagesChannel : messagesChannel,
          silent ? 'Silent messages' : 'Messages',
          importance: silent ? Importance.low : Importance.high,
          priority: silent ? Priority.low : Priority.high,
          category: AndroidNotificationCategory.message,
          playSound: !silent,
          enableVibration: !silent,
          actions: const [
            AndroidNotificationAction(
              'reply',
              'Reply in OpenChat',
              showsUserInterface: true,
            ),
          ],
        ),
      ),
      payload: NotifyTap(kind: 'msg', peer: peerId, name: name).encode(),
    );
    debugPrint('NotifyService: _plugin.show() completed');
  }

  /// Full-screen ringing that opens the app onto the incoming-call dialog.
  Future<void> showCall({
    required String inviteId,
    required String name,
    required bool video,
  }) async {
    if (!_ready) return;
    await _plugin.show(
      id: notificationId('call', inviteId),
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
          timeoutAfter: 60000,
        ),
      ),
      payload: NotifyTap(kind: 'call', peer: inviteId, name: name).encode(),
    );
  }

  Future<void> cancelCall(String inviteId) {
    if (!_ready) return Future.value();
    return _plugin.cancel(id: notificationId('call', inviteId));
  }

  Future<void> showMissedCall({
    required String inviteId,
    required String name,
    required bool video,
  }) async {
    if (!_ready) return;
    await _plugin.show(
      id: notificationId('missed_call', inviteId),
      title: 'Missed ${video ? 'video' : 'voice'} call',
      body: name,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          callsChannel,
          'Calls',
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.call,
          autoCancel: true,
        ),
      ),
      payload: NotifyTap(
        kind: 'missed_call',
        peer: inviteId,
        name: name,
      ).encode(),
    );
  }

  Future<void> showStatus({
    required String authorId,
    required String name,
    required String snippet,
    String? event,
  }) async {
    if (!_ready) return;
    if (!_newEvent('status', event)) return;
    await _plugin.show(
      id: notificationId('status', authorId),
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
    return _plugin.cancel(id: notificationId('msg', peerId));
  }

  Future<void> showGroup({
    required String groupId,
    required String groupName,
    required String senderName,
    String? event,
    bool ignoreOpenGroups = false,
  }) async {
    if (!_ready) return;
    if (!ignoreOpenGroups && openGroups.contains(groupId)) return;
    if (!_newEvent('group', event)) return;
    await _plugin.show(
      id: notificationId('group', groupId),
      title: groupName,
      body: '$senderName: New message',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          groupsChannel,
          'Group messages',
          importance: Importance.max,
          priority: Priority.high,
          category: AndroidNotificationCategory.message,
        ),
      ),
      payload: NotifyTap(
        kind: 'group',
        peer: groupId,
        name: groupName,
      ).encode(),
    );
  }

  Future<void> cancelGroup(String groupId) {
    if (!_ready) return Future.value();
    return _plugin.cancel(id: notificationId('group', groupId));
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
