import 'dart:async';
import 'dart:math';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'call_service.dart';
import 'call_signaling.dart';
import '../security/signal_crypto.dart';

enum CallDirection { incoming, outgoing }
enum CallType { voice, video }

class CallInfo {
  final String uuid;
  final String handle;
  final String name;
  final bool video;
  final CallDirection direction;
  final String? inviteId;
  final String? room;
  final String? mediaKey;
  final SupabaseClient? client;

  CallInfo({
    required this.uuid,
    required this.handle,
    required this.name,
    required this.video,
    required this.direction,
    this.inviteId,
    this.room,
    this.mediaKey,
    this.client,
  });

  Map<String, dynamic> toCallkitMap() => {
        'id': uuid,
        'name': name,
        'handle': handle,
        'type': video ? 1 : 0,
        'duration': 0,
        'extra': {
          'inviteId': inviteId,
          'room': room,
          'mediaKey': mediaKey,
          'peerId': handle,
        },
      };
}

/// Unified calling service: manages the native system call UI and the
/// LiveKit media path. On Android the Telecom ConnectionService
/// (OpenChatConnectionService.kt, wired through MainActivity) rings, and
/// media joins through [media] when the call is answered. The app shell
/// (home.dart) owns signaling, navigation and history logging via the
/// onIncoming* hooks.
class NativeCallService extends ChangeNotifier {
  static final NativeCallService _instance = NativeCallService._internal();
  factory NativeCallService() => _instance;
  NativeCallService._internal();

  final MethodChannel _channel = const MethodChannel('dev.openchat/calling_service');
  final CallService _media = CallService();
  final Map<String, CallInfo> _calls = {};

  CallService get media => _media;
  Map<String, CallInfo> get calls => Map.unmodifiable(_calls);

  bool get hasActiveCall => _calls.isNotEmpty;

  /// The system call UI (Telecom ConnectionService) accepted an incoming
  /// call. The app shell answers the invite, joins media through [media]
  /// and presents the call screen. When unset, NativeCallService joins
  /// media itself and presents no UI.
  Future<void> Function(CallInfo call)? onIncomingAccepted;

  /// The system call UI declined an incoming call, after the decline was
  /// reported to the caller.
  void Function(CallInfo call)? onIncomingDeclined;

  /// The system call UI ended a call (system end button, headset, or
  /// Telecom tearing the connection down).
  void Function(String uuid)? onCallUiEnded;

  @override
  void dispose() {
    _media.dispose();
    super.dispose();
  }

  /// Initialize native call handling. Call once at app startup.
  Future<void> initialize(SupabaseClient client) async {
    // Android ConnectionService channel
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      _channel.setMethodCallHandler((call) => _handleAndroidCall(call, client));
    }
  }

  // ==== Incoming calls (app shell -> native ring) ====

  /// Show the real system incoming-call UI: ringtone, lock screen and
  /// answer/decline buttons via the Android Telecom ConnectionService.
  /// Returns false when the platform refuses (no telecom, old Android, or
  /// a concurrent telecom call) so the shell can fall back to its in-app
  /// dialog. [inviteId] doubles as the Telecom call uuid so every native
  /// callback maps straight back to the invite row.
  Future<bool> ringIncoming({
    required String inviteId,
    required String peerId,
    required String peerName,
    required bool video,
    String? room,
    String? mediaKey,
    SupabaseClient? client,
  }) async {
    if (inviteId.isEmpty) return false;
    if (_calls.containsKey(inviteId)) return true; // already ringing
    _calls[inviteId] = CallInfo(
      uuid: inviteId,
      handle: peerId,
      name: peerName,
      video: video,
      direction: CallDirection.incoming,
      inviteId: inviteId,
      room: room,
      mediaKey: mediaKey,
      client: client,
    );
    notifyListeners();
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    try {
      final ok = await _channel.invokeMethod<bool>('reportIncomingCall', {
        'uuid': inviteId,
        'handle': peerId,
        'name': peerName,
        'video': video,
      });
      return ok == true;
    } on PlatformException {
      _calls.remove(inviteId);
      notifyListeners();
      return false;
    }
  }

  /// The remote side connected: tell Telecom to stop ringing and mark the
  /// connection active. No-op when there is no native connection.
  Future<void> reportCallConnected(String uuid) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>('reportCallConnected', {'uuid': uuid});
    } on PlatformException {
      // Connection already gone; nothing to report.
    }
  }

  /// Tear the native call UI down (caller gave up, or we ended our side).
  /// No-op when there is no native connection.
  Future<void> reportCallEnded(String uuid) async {
    _calls.remove(uuid);
    notifyListeners();
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>('reportCallEnded', {'uuid': uuid});
    } on PlatformException {
      // Connection already gone; nothing to report.
    }
  }

  // ==== Native callbacks ====

  Future<void> _handleAndroidCall(MethodCall call, SupabaseClient client) async {
    switch (call.method) {
      case 'onIncomingCall':
        final uuid = call.arguments['uuid'] as String;
        final handle = call.arguments['handle'] as String;
        final video = call.arguments['video'] as bool;
        final name = call.arguments['name'] as String;
        _onIncomingCall(client, uuid, handle, name, video, inviteId: null);
        break;
      case 'onCallAnswered':
        final uuid = call.arguments['uuid'] as String;
        _onCallAnswered(uuid);
        break;
      case 'onCallDeclined':
        final uuid = call.arguments['uuid'] as String;
        _onCallDeclined(uuid);
        break;
      case 'onCallEnded':
        final uuid = call.arguments['uuid'] as String;
        _onCallEnded(uuid);
        break;
    }
  }

  // Outgoing call
  Future<bool> startCall({
    required SupabaseClient client,
    required String peerId,
    required String peerName,
    required CallType type,
  }) async {
    if (!await _media.ensurePermissions(video: type == CallType.video)) {
      return false;
    }

    final me = client.auth.currentUser!.id;
    final mediaKey = base64UrlEncode(
      List<int>.generate(32, (_) => Random.secure().nextInt(256)),
    ).replaceAll('=', '');

    String encryptedCallKey;
    try {
      encryptedCallKey = await SignalCrypto(
        client: client,
        accountId: me,
        preferences: await SharedPreferences.getInstance(),
      ).encryptText(peerId, mediaKey);
    } catch (e) {
      return false;
    }

    // Place call invite
    final invite = await CallSignaling.place(
      client,
      peerId: peerId,
      callType: type == CallType.video ? 'video' : 'voice',
      encryptedCallKey: encryptedCallKey,
    );

    final uuid = const Uuid().v4();
    final callInfo = CallInfo(
      uuid: uuid,
      handle: peerId,
      name: peerName,
      video: type == CallType.video,
      direction: CallDirection.outgoing,
      inviteId: invite.inviteId,
      room: invite.room,
      mediaKey: mediaKey,
      client: client,
    );
    _calls[uuid] = callInfo;
    notifyListeners();

    // Start native outgoing call UI
    if (kIsWeb) {
      return _joinMedia(client, invite.room, invite.inviteId, mediaKey);
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      // iOS: flutter_callkit_incoming integration pending native AppDelegate
      // For now, fall back to in-app dialog
    } else {
      // Android: ConnectionService pending native implementation
      // For now, fall back to in-app dialog
    }
    return true;
  }

  Future<bool> _joinMedia(SupabaseClient client, String room, String inviteId, String mediaKey) async {
    try {
      final token = await CallSignaling.token(
        client,
        room: room,
        name: client.auth.currentUser!.id,
      );
      return await _media.join(
        url: token.url,
        token: token.token,
        video: true,
        mediaKey: mediaKey,
      );
    } catch (e) {
      return false;
    }
  }

  void _onCallAnswered(String uuid) {
    final call = _calls[uuid];
    if (call == null) return;

    if (call.direction == CallDirection.incoming) {
      // The shell owns the full accept flow (answer RPC, media join through
      // [media] and navigation). Fall back to media-only when no shell is
      // wired (headless tests).
      final accepted = onIncomingAccepted;
      if (accepted != null) {
        unawaited(accepted(call));
      } else {
        unawaited(_joinMediaForCall(call));
      }
      return;
    }
    unawaited(_joinMediaForCall(call));
  }

  void _onCallDeclined(String uuid) {
    final call = _calls[uuid];
    if (call == null) return;

    if (call.direction == CallDirection.incoming && call.inviteId != null && call.client != null) {
      unawaited(
        CallSignaling.answer(call.client!, inviteId: call.inviteId!, accept: false)
            .catchError((_) {}),
      );
    }
    onIncomingDeclined?.call(call);
    _endCall(uuid);
  }

  void _onCallEnded(String uuid) {
    onCallUiEnded?.call(uuid);
    _endCall(uuid);
  }

  void _onIncomingCall(SupabaseClient client, String uuid, String handle, String name, bool video, {String? inviteId}) {
    // ringIncoming already registered this call with full context (room,
    // media key, client); the native event only confirms Telecom picked it
    // up. Never overwrite it with a contextless entry.
    if (_calls.containsKey(uuid)) return;
    final callInfo = CallInfo(
      uuid: uuid,
      handle: handle,
      name: name,
      video: video,
      direction: CallDirection.incoming,
      inviteId: inviteId,
      client: client,
    );
    _calls[uuid] = callInfo;
    notifyListeners();
  }

  Future<void> _joinMediaForCall(CallInfo call) async {
    if (call.room == null || call.mediaKey == null) return;

    try {
      final token = await CallSignaling.token(
        call.client!,
        room: call.room!,
        name: call.client!.auth.currentUser!.id,
      );
      await _media.join(
        url: token.url,
        token: token.token,
        video: call.video,
        mediaKey: call.mediaKey!,
      );
    } catch (e) {
      // Error handled by CallService
    }
  }

  void _endCall(String uuid) {
    _calls.remove(uuid);
    if (_calls.isEmpty) {
      _media.hangUp();
    }
    notifyListeners();
  }

  Future<void> endAllCalls() async {
    for (final uuid in _calls.keys.toList()) {
      _endCall(uuid);
    }
  }
}