import 'dart:async';

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../ops/error_report.dart';
import 'call_service.dart';
import 'call_signaling.dart';

/// Drop-in group voice chats (WhatsApp-style audio rooms).
///
/// Unlike 1:1 calls these never ring anyone: the moment the first member
/// joins, a row in `group_voice_rooms` (published over realtime) makes every
/// member's app show a "voice chat" banner they can tap to join or leave.
/// The `join_group_voice` / `leave_group_voice` RPCs enforce group membership
/// server-side and maintain the participant count; the LiveKit SFU provides
/// the real-time count while we are connected. Media is DTLS-SRTP encrypted;
/// there is no app-layer E2EE key for group rooms.
class GroupVoiceChatService extends ChangeNotifier {
  GroupVoiceChatService._internal();
  static final GroupVoiceChatService instance = GroupVoiceChatService._internal();

  SupabaseClient? _client;
  CallService? _media;
  RealtimeChannel? _roomsWatch;
  String? _watchUid;
  void Function()? _cancelRoomEvents;

  final Map<String, GroupVoiceRoom> _rooms = {};
  String? _currentConversationId;
  bool _isInRoom = false;
  bool _joining = false;
  bool _muted = false;
  bool _speakerOn = true;
  String? _error;

  Map<String, GroupVoiceRoom> get rooms => Map.unmodifiable(_rooms);
  bool get isInRoom => _isInRoom;
  bool get joining => _joining;
  String? get currentConversationId => _currentConversationId;
  bool get muted => _muted;
  bool get speakerOn => _speakerOn;
  String? get error => _error;

  /// Whether an audio room is ongoing for [conversationId].
  bool isActive(String conversationId) =>
      _rooms[conversationId] != null && _rooms[conversationId]!.participantCount > 0;

  /// The ongoing room info for a conversation, if any.
  GroupVoiceRoom? getRoom(String conversationId) => _rooms[conversationId];

  /// Watch group voice rooms for the signed-in user. Idempotent per uid,
  /// like the other home-screen watchers.
  void start(SupabaseClient client) {
    final uid = client.auth.currentUser?.id;
    if (uid == null) return;
    if (_watchUid == uid && _roomsWatch != null) return;
    stop();
    _client = client;
    _watchUid = uid;
    _roomsWatch = client.channel('group-voice-rooms:$uid')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'group_voice_rooms',
        callback: _onRoomChange,
      )
      ..subscribe();
    unawaited(_refreshRooms());
  }

  /// Unsubscribe and drop all room state. Used on sign-out / teardown.
  void stop() {
    _roomsWatch?.unsubscribe();
    _roomsWatch = null;
    _watchUid = null;
    _client = null;
    _rooms.clear();
    if (_isInRoom) {
      unawaited(leave(notifyServer: false));
    }
    notifyListeners();
  }

  Future<void> _refreshRooms() async {
    final client = _client;
    if (client == null) return;
    try {
      final rows = await client
          .from('group_voice_rooms')
          .select(
            'conversation_id, room_name, started_by, participant_count, started_at',
          );
      final next = <String, GroupVoiceRoom>{};
      for (final row in rows as List<dynamic>) {
        final room = _roomFromMap(row as Map<String, dynamic>);
        if (room != null) next[room.conversationId] = room;
      }
      _rooms
        ..clear()
        ..addAll(next);
      notifyListeners();
    } catch (e) {
      ErrorReport.report(
        area: 'group-voice',
        code: 'refresh_failed',
        details: {'error': e.toString()},
      );
    }
  }

  void _onRoomChange(PostgresChangePayload payload) {
    switch (payload.eventType) {
      case PostgresChangeEvent.insert:
      case PostgresChangeEvent.update:
        final room = _roomFromMap(payload.newRecord);
        if (room != null) _rooms[room.conversationId] = room;
        break;
      case PostgresChangeEvent.delete:
        final id = payload.oldRecord['conversation_id'] as String?;
        if (id != null) _rooms.remove(id);
        break;
      default:
        break;
    }
    notifyListeners();
  }

  GroupVoiceRoom? _roomFromMap(Map<String, dynamic> row) {
    final id = row['conversation_id'] as String?;
    if (id == null || id.isEmpty) return null;
    return GroupVoiceRoom(
      conversationId: id,
      roomName: row['room_name'] as String? ?? '',
      startedBy: row['started_by'] as String? ?? '',
      startedAt:
          DateTime.tryParse(row['started_at'] as String? ?? '') ??
          DateTime.now(),
      participantCount: ((row['participant_count'] as num?)?.toInt() ?? 1)
          .clamp(1, 1000),
    );
  }

  /// Join (or start) the drop-in room for a group. Starting is joining: the
  /// first `join_group_voice` call inserts the presence row that every other
  /// member sees.
  Future<bool> join({
    required BuildContext context,
    required SupabaseClient client,
    required String conversationId,
    required String conversationTitle,
  }) async {
    if (_joining) return false;
    final messenger = ScaffoldMessenger.of(context);
    _joining = true;
    _error = null;
    notifyListeners();

    final media = _media ?? CallService();
    _media = media;

    if (!await media.ensurePermissions(video: false)) {
      _joining = false;
      notifyListeners();
      messenger.showSnackBar(
        SnackBar(
          content: Text(media.error ?? 'Microphone permission is required.'),
        ),
      );
      return false;
    }

    try {
      // Membership is verified server-side; returns the LiveKit room name.
      final roomName = await client.rpc(
        'join_group_voice',
        params: {'p_conversation_id': conversationId},
      ) as String;

      final creds = await CallSignaling.token(
        client,
        room: roomName,
        name: client.auth.currentUser!.id,
      );
      final joined = await media.join(
        url: creds.url,
        token: creds.token,
        video: false,
        mediaKey: null, // drop-in rooms use DTLS-SRTP transport only
      );
      if (!joined) {
        // Roll the presence row back so nobody sees a phantom seat.
        unawaited(_serverLeave(client, conversationId));
        _joining = false;
        notifyListeners();
        messenger.showSnackBar(
          SnackBar(
            content: Text(media.error ?? 'Could not join the voice chat.'),
          ),
        );
        return false;
      }

      // Leaving any previous room this session: free that seat too.
      final previousId = _currentConversationId;
      _cancelRoomEvents?.call();
      _cancelRoomEvents = null;
      if (previousId != null && previousId != conversationId) {
        unawaited(_serverLeave(client, previousId));
      }

      _currentConversationId = conversationId;
      _isInRoom = true;
      _muted = false;
      _speakerOn = true;
      _joining = false;
      // Drop-in rooms are speakerphone-first (1:1 calls use the earpiece).
      await media.setSpeakerPreferred(true);

      // The SFU knows the real count; the table row is only the banner hint.
      final liveRoom = media.room;
      if (liveRoom != null) {
        _cancelRoomEvents = liveRoom.events.listen((event) {
          if (event is ParticipantConnectedEvent ||
              event is ParticipantDisconnectedEvent) {
            _syncLiveCount();
          } else if (event is RoomDisconnectedEvent) {
            // The SFU dropped us (network); keep presence for a clean
            // rejoin instead of tearing the group room down.
            ErrorReport.report(
              area: 'group-voice',
              code: 'room_disconnected',
            );
          }
          notifyListeners();
        });
      }

      // Optimistic entry so our own banner shows immediately; realtime
      // events and _syncLiveCount correct it.
      final server = _rooms[conversationId];
      _rooms[conversationId] = GroupVoiceRoom(
        conversationId: conversationId,
        roomName: roomName,
        startedBy: server?.startedBy ?? client.auth.currentUser!.id,
        startedAt: server?.startedAt ?? DateTime.now(),
        participantCount: (server?.participantCount ?? 0) + 1,
      );
      notifyListeners();
      return true;
    } catch (e) {
      _joining = false;
      _error = 'Could not join the voice chat. Check your connection.';
      notifyListeners();
      ErrorReport.report(
        area: 'group-voice',
        code: 'join_failed',
        details: {'error': e.toString()},
      );
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Could not join the voice chat. Check your connection.'),
        ),
      );
      return false;
    }
  }

  /// Leave the current room (and only that room).
  Future<void> leave({bool notifyServer = true}) async {
    final conversationId = _currentConversationId;
    final media = _media;
    _cancelRoomEvents?.call();
    _cancelRoomEvents = null;
    _currentConversationId = null;
    _isInRoom = false;
    notifyListeners();
    if (media != null) {
      try {
        await media.hangUp();
      } catch (_) {}
    }
    final client = _client;
    if (notifyServer && conversationId != null && client != null) {
      await _serverLeave(client, conversationId);
    }
  }

  Future<void> _serverLeave(SupabaseClient client, String conversationId) async {
    try {
      await client.rpc(
        'leave_group_voice',
        params: {'p_conversation_id': conversationId},
      );
    } catch (_) {
      // The join RPC also heals stale counts; nothing to do here.
    }
  }

  void _syncLiveCount() {
    final id = _currentConversationId;
    final live = _media?.room;
    final existing = id != null ? _rooms[id] : null;
    if (id == null || live == null || existing == null) return;
    final count = live.remoteParticipants.length + 1;
    if (count == existing.participantCount) return;
    _rooms[id] = GroupVoiceRoom(
      conversationId: existing.conversationId,
      roomName: existing.roomName,
      startedBy: existing.startedBy,
      startedAt: existing.startedAt,
      participantCount: count.clamp(1, 1000),
    );
  }

  Future<void> toggleMute() async {
    final media = _media;
    if (media == null || !_isInRoom) return;
    await media.toggleMute();
    _muted = media.muted;
    notifyListeners();
  }

  Future<void> toggleSpeaker() async {
    final media = _media;
    if (media == null || !_isInRoom) return;
    await media.toggleSpeaker();
    _speakerOn = media.speakerOn;
    notifyListeners();
  }

  @override
  void dispose() {
    _cancelRoomEvents?.call();
    _roomsWatch?.unsubscribe();
    _roomsWatch = null;
    _media?.dispose();
    _media = null;
    super.dispose();
  }
}

/// One ongoing drop-in room, as seen on this device.
class GroupVoiceRoom {
  GroupVoiceRoom({
    required this.conversationId,
    required this.roomName,
    required this.startedBy,
    required this.startedAt,
    required this.participantCount,
  });

  final String conversationId;
  final String roomName;
  final String startedBy;
  final DateTime startedAt;
  final int participantCount;

  bool get isActive => participantCount > 0;
}

/// Banner shown inside a group chat while a voice room is ongoing.
class GroupVoiceChatBanner extends StatelessWidget {
  const GroupVoiceChatBanner({
    super.key,
    required this.conversationId,
    required this.conversationTitle,
    required this.participantCount,
    required this.onJoin,
    required this.onDismiss,
    this.isCurrentUserIn = false,
    this.onLeave,
  });
  final String conversationId;
  final String conversationTitle;
  final int participantCount;
  final VoidCallback onJoin;
  final VoidCallback onDismiss;
  final bool isCurrentUserIn;
  final VoidCallback? onLeave;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1A2A3A) : const Color(0xFFE3F2FD),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? const Color(0xFF2A4A6A) : const Color(0xFF90CAF9),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: isCurrentUserIn
                  ? (isDark ? Colors.green[900] : Colors.green[100])
                  : (isDark ? Colors.blue[900] : Colors.blue[100]),
              shape: BoxShape.circle,
            ),
            child: Icon(
              isCurrentUserIn ? Icons.mic : Icons.mic_none,
              color: isCurrentUserIn
                  ? (isDark ? Colors.green[300] : Colors.green[700])
                  : (isDark ? Colors.blue[300] : Colors.blue[700]),
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Group voice chat',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                Text(
                  '$participantCount participant${participantCount == 1 ? '' : 's'} • Tap to ${isCurrentUserIn ? 'leave' : 'join'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: isDark ? Colors.white70 : Colors.black54,
                  ),
                ),
              ],
            ),
          ),
          if (isCurrentUserIn)
            TextButton.icon(
              onPressed: onLeave,
              icon: const Icon(Icons.call_end, size: 18),
              label: const Text('Leave'),
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
            )
          else
            FilledButton(
              onPressed: onJoin,
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.primary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
              child: const Text('Join'),
            ),
          IconButton(
            onPressed: onDismiss,
            icon: const Icon(Icons.close, size: 20),
            tooltip: 'Dismiss',
          ),
        ],
      ),
    );
  }
}
