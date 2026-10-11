import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';

/// Deterministic 1:1 room for two user ids. Both sides compute the same
/// name, so no room bookkeeping is needed anywhere.
String callRoomFor(String a, String b) {
  final ids = [a, b]..sort();
  return 'dm_${ids[0]}_${ids[1]}';
}

enum LiveCallState { idle, joining, ringing, connected, reconnecting, ended, failed }

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

  bool get remoteAudio {
    if (_room == null) return false;
    for (final p in _room!.remoteParticipants.values) {
      if (p.audioTrackPublications.isNotEmpty) return true;
    }
    return false;
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

  Future<bool> join({
    required String url,
    required String token,
    required bool video,
  }) async {
    error = null;
    state = LiveCallState.joining;
    notifyListeners();
    try {
      final room = Room();
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
