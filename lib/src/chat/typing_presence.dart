import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Manages typing indicators and presence state via Supabase Realtime Presence.
///
/// Each conversation has a Presence channel where members broadcast:
/// - typing status (auto-expires after 3 seconds of inactivity)
/// - recording audio status
/// - online presence
class TypingPresence {
  TypingPresence({
    required this.client,
    required this.conversationId,
    required this.userId,
    required this.displayName,
    required this.onPresenceChange,
  });

  final SupabaseClient client;
  final String conversationId;
  final String userId;
  final String displayName;

  /// Called whenever typing presence state changes for any participant.
  final void Function(Map<String, PresenceState> states) onPresenceChange;

  RealtimeChannel? _channel;
  Timer? _typingExpiry;
  Timer? _debounce;
  bool _active = true;
  bool _subscribed = false;
  bool _isTyping = false;
  bool _isRecording = false;

  /// Active presence states keyed by user id.
  final Map<String, PresenceState> _states = {};

  /// Joins the presence channel for this conversation.
  void join() {
    if (_channel != null) return;
    final channelName = 'presence:$conversationId';
    _channel = client.channel(channelName);

    _channel!
      ..onPresenceSync((payload) {
        _syncPresence();
      })
      ..onPresenceJoin((payload) {
        _syncPresence();
      })
      ..onPresenceLeave((payload) {
        _syncPresence();
      })
      ..subscribe((status, [error]) {
        _subscribed = status == RealtimeSubscribeStatus.subscribed;
        if (status == RealtimeSubscribeStatus.subscribed) {
          _broadcastState();
        }
      });
  }

  void _syncPresence() {
    if (_channel == null) return;

    final presenceList = _channel!.presenceState();
    _states.clear();

    for (final state in presenceList) {
      for (final presence in state.presences) {
        final payload = presence.payload;
        final uid = payload['user_id'] as String? ?? '';
        if (uid.isEmpty || uid == userId) continue;

        _states[uid] = PresenceState(
          userId: uid,
          displayName: payload['display_name'] as String? ?? 'User',
          isTyping: payload['typing'] as bool? ?? false,
          isRecording: payload['recording'] as bool? ?? false,
          isOnline: true,
        );
      }
    }

    onPresenceChange(_states);
  }

  /// Call on every keystroke in the text input. Automatically debounces and
  /// expires typing status after 3 seconds of inactivity.
  void onKeystroke() {
    if (!_active) return;
    _debounce?.cancel();

    if (!_isTyping) {
      _isTyping = true;
      _broadcastState();
    }

    // Auto-expire typing after 3 seconds of no keystrokes
    _typingExpiry?.cancel();
    _typingExpiry = Timer(const Duration(seconds: 3), () {
      _isTyping = false;
      _broadcastState();
    });
  }

  /// Call when the user starts recording audio.
  void startRecording() {
    _isRecording = true;
    _isTyping = false;
    _typingExpiry?.cancel();
    _broadcastState();
  }

  /// Call when the user stops recording audio.
  void stopRecording() {
    _isRecording = false;
    _broadcastState();
  }

  /// Call when the text field loses focus or input is cleared.
  void stopTyping() {
    _isTyping = false;
    _typingExpiry?.cancel();
    _broadcastState();
  }

  void setActive(bool active) {
    _active = active;
    if (!active) {
      _isTyping = false;
      _isRecording = false;
      _typingExpiry?.cancel();
    }
    _broadcastState();
  }

  Future<void> _broadcastState() async {
    final channel = _channel;
    if (channel == null || !_subscribed) return;
    try {
      if (!_active) {
        await channel.untrack();
      } else {
        await channel.track({
          'user_id': userId,
          'display_name': displayName,
          'status': 'online',
          'typing': _isTyping,
          'recording': _isRecording,
        });
      }
    } catch (_) {}
  }

  /// Builds a human-readable status line from current presence states.
  /// Examples: "Maya is typing...", "Leo is recording audio...",
  /// "Maya, Leo are typing..."
  String? get statusText {
    final typing = _states.values.where((s) => s.isTyping).toList();
    final recording = _states.values.where((s) => s.isRecording).toList();

    if (recording.isNotEmpty) {
      if (recording.length == 1) {
        return '${recording.first.displayName} is recording audio...';
      }
      return '${recording.map((s) => s.displayName).join(', ')} are recording audio...';
    }

    if (typing.isNotEmpty) {
      if (typing.length == 1) {
        return '${typing.first.displayName} is typing...';
      }
      if (typing.length <= 3) {
        return '${typing.map((s) => s.displayName).join(', ')} are typing...';
      }
      return '${typing.length} people are typing...';
    }

    return null;
  }

  /// Returns the online status text for a 1-on-1 peer.
  String? get peerOnlineText {
    if (_states.length != 1) return null;
    final peer = _states.values.first;
    if (peer.isTyping) return 'typing...';
    if (peer.isRecording) return 'recording audio...';
    if (peer.isOnline) return 'online';
    return null;
  }

  void dispose() {
    _typingExpiry?.cancel();
    _debounce?.cancel();
    final channel = _channel;
    _channel = null;
    _subscribed = false;
    if (channel != null) unawaited(client.removeChannel(channel));
  }
}

class PresenceState {
  const PresenceState({
    required this.userId,
    required this.displayName,
    this.isTyping = false,
    this.isRecording = false,
    this.isOnline = false,
  });

  final String userId;
  final String displayName;
  final bool isTyping;
  final bool isRecording;
  final bool isOnline;
}
