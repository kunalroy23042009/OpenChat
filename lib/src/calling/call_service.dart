import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';

/// Per-call rooms are generated server-side (`call_<32 hex>`). The legacy
/// deterministic `dm_<uuid>_<uuid>` form is still accepted so in-flight calls
/// survive a deploy. Both the app and the token function share this shape.
final RegExp callRoomPattern = RegExp(
  r'^(call_[0-9a-f]{32}|dm_[0-9a-f-]{36}_[0-9a-f-]{36})$',
);

/// True when [room] looks like a valid call room name.
bool isValidCallRoom(String room) =>
    room.isNotEmpty && room.length <= 128 && callRoomPattern.hasMatch(room);

enum LiveCallState {
  idle,
  joining,
  ringing,
  connected,
  reconnecting,
  ended,
  failed,
}

/// Foreground 1:1 voice/video calling over LiveKit. Media never touches
/// our backend: audio/video flows phone <-> LiveKit SFU, encrypted with
/// DTLS-SRTP. Signaling (who rings whom) goes through Supabase.
class CallService extends ChangeNotifier {
  Room? _room;
  void Function()? _cancelEvents;
  LiveCallState state = LiveCallState.idle;
  bool muted = false;
  bool videoOff = false;
  bool speakerOn = true;
  bool frontCamera = true;
  bool remoteJoined = false;
  String? error;

  Room? get room => _room;

  VideoTrack? get localVideo {
    final pubs = _room?.localParticipant?.videoTrackPublications;
    if (pubs == null || pubs.isEmpty) return null;
    return pubs.first.track as VideoTrack?;
  }

  VideoTrack? get remoteVideo {
    if (_room == null) return null;
    for (final p in _room!.remoteParticipants.values) {
      for (final pub in p.videoTrackPublications) {
        final track = pub.track;
        if (track is VideoTrack) return track;
      }
    }
    return null;
  }

  Future<bool> ensurePermissions({required bool video}) async {
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      error = 'Microphone permission is required to call.';
      notifyListeners();
      return false;
    }
    if (video) {
      final cam = await Permission.camera.request();
      if (!cam.isGranted) {
        error = 'Camera permission is required for video calls.';
        notifyListeners();
        return false;
      }
    }
    return true;
  }

  /// [mediaKey] enables the app-layer E2EE (1:1 calls). Group voice rooms
  /// pass null: media is still protected in transit by DTLS-SRTP between
  /// participants and the LiveKit SFU.
  Future<bool> join({
    required String url,
    required String token,
    required bool video,
    String? mediaKey,
  }) async {
    error = null;
    state = LiveCallState.joining;
    notifyListeners();
    try {
      final Room room;
      if (mediaKey == null || mediaKey.isEmpty) {
        room = Room();
      } else {
        final rawKey = Uint8List.fromList(
          base64Url.decode(base64Url.normalize(mediaKey)),
        );
        if (rawKey.length != 32) {
          throw StateError('End-to-end call encryption key is invalid.');
        }
        final keyProvider = await BaseKeyProvider.create();
        await keyProvider.setRawKey(rawKey);
        rawKey.fillRange(0, rawKey.length, 0);
        final e2eeOptions = E2EEOptions(keyProvider: keyProvider);
        room = Room(roomOptions: RoomOptions(encryption: e2eeOptions));
      }
      _room = room;
      _cancelEvents = room.events.listen(_onEvent);
      await room.connect(url, token);
      await room.localParticipant?.setMicrophoneEnabled(true);
      if (video) {
        await room.localParticipant?.setCameraEnabled(true);
        await AudioManager.instance.setSpeakerOutputPreferred(true);
      } else {
        await AudioManager.instance.setSpeakerOutputPreferred(false);
      }
      state = LiveCallState.ringing;
      notifyListeners();
      return true;
    } catch (e) {
      state = LiveCallState.failed;
      error = 'Could not join the call. Check your connection.';
      notifyListeners();
      await _leave();
      return false;
    }
  }

  void _onEvent(RoomEvent event) {
    if (event is RoomConnectedEvent ||
        event is ParticipantConnectedEvent ||
        event is TrackSubscribedEvent) {
      remoteJoined = true;
      if (state == LiveCallState.ringing) state = LiveCallState.connected;
      notifyListeners();
    } else if (event is RoomReconnectingEvent) {
      state = LiveCallState.reconnecting;
      notifyListeners();
    } else if (event is RoomDisconnectedEvent) {
      state = LiveCallState.ended;
      notifyListeners();
    }
  }

  Future<void> toggleMute() async {
    muted = !muted;
    try {
      await _room?.localParticipant?.setMicrophoneEnabled(!muted);
    } catch (_) {
      muted = !muted;
    }
    notifyListeners();
  }

  Future<void> toggleVideo() async {
    videoOff = !videoOff;
    try {
      await _room?.localParticipant?.setCameraEnabled(!videoOff);
    } catch (_) {
      videoOff = !videoOff;
    }
    notifyListeners();
  }

  Future<void> switchCamera() async {
    try {
      final pubs = _room?.localParticipant?.videoTrackPublications;
      if (pubs == null || pubs.isEmpty) return;
      final track = pubs.first.track;
      if (track is LocalVideoTrack) {
        frontCamera = !frontCamera;
        await track.setCameraPosition(
          frontCamera ? CameraPosition.front : CameraPosition.back,
        );
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> toggleSpeaker() async {
    speakerOn = !speakerOn;
    try {
      await AudioManager.instance.setSpeakerOutputPreferred(speakerOn);
    } catch (_) {}
    notifyListeners();
  }

  /// Group voice rooms want the loudspeaker by default, unlike 1:1 voice
  /// calls which join on the earpiece.
  Future<void> setSpeakerPreferred(bool on) async {
    speakerOn = on;
    try {
      await AudioManager.instance.setSpeakerOutputPreferred(on);
    } catch (_) {}
  }

  Future<void> _leave() async {
    _cancelEvents?.call();
    _cancelEvents = null;
    try {
      await _room?.disconnect();
    } catch (_) {}
    try {
      await _room?.dispose();
    } catch (_) {}
    _room = null;
  }

  Future<void> hangUp() async {
    await _leave();
    state = LiveCallState.ended;
    notifyListeners();
  }

  @override
  void dispose() {
    _leave();
    super.dispose();
  }
}
