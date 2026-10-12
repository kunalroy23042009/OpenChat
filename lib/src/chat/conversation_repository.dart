import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Data models for group/channel conversations and messages.

class GroupConversation {
  GroupConversation({
    required this.id,
    required this.type,
    this.title,
    this.description,
    this.avatarUrl,
    this.inviteCode,
    this.requireApproval = false,
    this.createdBy,
    this.createdAt,
    this.myRole = 'member',
    this.isMuted = false,
    this.isPinned = false,
    this.isArchived = false,
    this.unreadCount = 0,
    this.lastActivity,
    this.lastMessage,
  });

  final String id;
  final String type; // 'direct', 'group', 'channel'
  final String? title;
  final String? description;
  final String? avatarUrl;
  final String? inviteCode;
  final bool requireApproval;
  final String? createdBy;
  final DateTime? createdAt;
  final String myRole;
  final bool isMuted;
  final bool isPinned;
  final bool isArchived;
  final int unreadCount;
  final DateTime? lastActivity;
  final String? lastMessage;

  bool get isGroup => type == 'group';
  bool get isChannel => type == 'channel';
  bool get isDirect => type == 'direct';
  bool get isAdmin => myRole == 'admin' || myRole == 'owner';
  bool get isOwner => myRole == 'owner';

  factory GroupConversation.fromJson(Map<String, dynamic> json) =>
      GroupConversation(
        id: json['id'] as String,
        type: json['type'] as String,
        title: json['title'] as String?,
        description: json['description'] as String?,
        avatarUrl: json['avatar_url'] as String?,
        inviteCode: json['invite_code'] as String?,
        requireApproval: json['require_approval'] as bool? ?? false,
        createdBy: json['created_by'] as String?,
        createdAt: json['created_at'] != null
            ? DateTime.tryParse(json['created_at'] as String)
            : null,
        myRole: json['my_role'] as String? ?? 'member',
        isMuted: json['is_muted'] as bool? ?? false,
        isPinned: json['is_pinned'] as bool? ?? false,
        isArchived: json['is_archived'] as bool? ?? false,
        unreadCount: json['unread_count'] as int? ?? 0,
        lastActivity: json['last_activity'] != null
            ? DateTime.tryParse(json['last_activity'] as String)
            : null,
        lastMessage: json['last_message'] as String?,
      );
}

class GroupMessage {
  GroupMessage({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.content,
    required this.type,
    required this.createdAt,
    this.senderName,
    this.parentMessageId,
    this.mediaUrl,
    this.metadata,
    this.isEdited = false,
    this.editedAt,
    this.isDeleted = false,
    this.isViewOnce = false,
    this.isForwarded = false,
    this.forwardCount = 0,
    this.reactions = const [],
    this.isPinned = false,
    this.isStarred = false,
  });

  final String id;
  final String conversationId;
  final String senderId;
  final String content;
  final String type;
  final DateTime createdAt;
  final String? senderName;
  final String? parentMessageId;
  final String? mediaUrl;
  final Map<String, dynamic>? metadata;
  final bool isEdited;
  final DateTime? editedAt;
  final bool isDeleted;
  final bool isViewOnce;
  final bool isForwarded;
  final int forwardCount;
  final List<MessageReaction> reactions;
  final bool isPinned;
  final bool isStarred;

  bool get isEditable =>
      createdAt.isAfter(DateTime.now().subtract(const Duration(minutes: 15)));

  Map<String, List<String>> get reactionsGrouped {
    final map = <String, List<String>>{};
    for (final r in reactions) {
      map.putIfAbsent(r.emoji, () => []).add(r.userId);
    }
    return map;
  }

  factory GroupMessage.fromJson(Map<String, dynamic> json) => GroupMessage(
    id: json['id'] as String,
    conversationId: json['conversation_id'] as String,
    senderId: json['sender_id'] as String,
    content: json['content'] as String,
    type: json['type'] as String? ?? 'text',
    createdAt: DateTime.parse(json['created_at'] as String),
    senderName: json['sender_name'] as String?,
    parentMessageId: json['parent_message_id'] as String?,
    mediaUrl: json['media_url'] as String?,
    metadata: json['metadata'] as Map<String, dynamic>?,
    isEdited: json['is_edited'] as bool? ?? false,
    editedAt: json['edited_at'] != null
        ? DateTime.tryParse(json['edited_at'] as String)
        : null,
    isDeleted: json['is_deleted'] as bool? ?? false,
    isViewOnce: json['is_view_once'] as bool? ?? false,
    isForwarded: json['is_forwarded'] as bool? ?? false,
    forwardCount: json['forward_count'] as int? ?? 0,
    isPinned: json['is_pinned'] as bool? ?? false,
    isStarred: json['is_starred'] as bool? ?? false,
    reactions:
        (json['reactions'] as List<dynamic>?)
            ?.map((r) => MessageReaction.fromJson(r as Map<String, dynamic>))
            .toList() ??
        const [],
  );
}

class MessageReaction {
  const MessageReaction({required this.emoji, required this.userId});
  final String emoji;
  final String userId;

  factory MessageReaction.fromJson(Map<String, dynamic> json) =>
      MessageReaction(
        emoji: json['emoji'] as String,
        userId: json['user_id'] as String,
      );
}

class TeamTask {
  const TeamTask({
    required this.id,
    required this.title,
    required this.status,
    required this.priority,
    this.description,
    this.assigneeId,
    this.dueDate,
  });

  final String id;
  final String title;
  final String status;
  final String priority;
  final String? description;
  final String? assigneeId;
  final DateTime? dueDate;

  factory TeamTask.fromJson(Map<String, dynamic> json) => TeamTask(
    id: json['id'] as String,
    title: json['title'] as String,
    status: json['status'] as String,
    priority: json['priority'] as String,
    description: json['description'] as String?,
    assigneeId: json['assignee_id'] as String?,
    dueDate: json['due_date'] == null
        ? null
        : DateTime.parse(json['due_date'] as String),
  );
}

/// Repository for group/channel conversation operations via Supabase RPCs.
class ConversationRepository extends ChangeNotifier {
  ConversationRepository(this.client);

  final SupabaseClient client;
  List<GroupConversation> _conversations = [];
  final Map<String, List<GroupMessage>> _messages = {};
  final Map<String, Set<String>> _starredMessages = {};
  final Map<String, List<TeamTask>> _tasks = {};
  bool _loading = false;
  String? _error;

  List<GroupConversation> get conversations => _conversations;
  bool get loading => _loading;
  String? get error => _error;

  String get _userId => client.auth.currentUser!.id;

  List<GroupMessage> messagesFor(String conversationId) =>
      _messages[conversationId] ?? [];

  bool isStarred(String messageId) =>
      _starredMessages[_userId]?.contains(messageId) ?? false;

  List<TeamTask> tasksFor(String conversationId) =>
      _tasks[conversationId] ?? const [];

  Future<void> loadTasks(String conversationId) async {
    final rows =
        await client
                .from('tasks')
                .select()
                .eq('conversation_id', conversationId)
                .order('created_at')
            as List<dynamic>;
    _tasks[conversationId] = rows
        .cast<Map<String, dynamic>>()
        .map(TeamTask.fromJson)
        .toList();
    notifyListeners();
  }

  Future<void> createTask(
    String conversationId,
    String title, {
    String? description,
    String? assigneeId,
    DateTime? dueDate,
    String priority = 'medium',
    String? messageId,
  }) async {
    await client.rpc(
      'create_task',
      params: {
        'p_conversation_id': conversationId,
        'p_title': title,
        'p_description': description,
        'p_assignee_id': assigneeId,
        'p_due_date': dueDate?.toIso8601String(),
        'p_priority': priority,
        'p_message_id': messageId,
      },
    );
    await loadTasks(conversationId);
  }

  Future<void> updateTaskStatus(
    String conversationId,
    String taskId,
    String status,
  ) async {
    await client.rpc(
      'update_task_status',
      params: {'p_task_id': taskId, 'p_status': status},
    );
    await loadTasks(conversationId);
  }

  Future<void> createPoll(
    String conversationId,
    String question,
    List<String> options, {
    bool multiple = false,
  }) async {
    await client.rpc(
      'create_poll',
      params: {
        'p_conversation_id': conversationId,
        'p_question': question,
        'p_options': options,
        'p_multiple': multiple,
      },
    );
    await loadMessages(conversationId);
  }

  Future<void> votePoll(
    String conversationId,
    String messageId,
    int option,
  ) async {
    await client.rpc(
      'vote_poll',
      params: {'p_message_id': messageId, 'p_option_index': option},
    );
    await loadMessages(conversationId);
  }

  // ========== Conversations ==========

  /// Fetches all conversations for the current user.
  Future<void> loadConversations() async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      final result = await client.rpc(
        'list_conversations',
        params: {'p_limit': 100, 'p_offset': 0},
      ) as List<dynamic>;

      _conversations = result
          .cast<Map<String, dynamic>>()
          .map(GroupConversation.fromJson)
          .toList();
    } catch (e) {
      _error = 'Failed to load conversations: $e';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Creates a new group or channel.
  Future<String> createGroup({
    required String title,
    String? description,
    String? avatarUrl,
    bool isChannel = false,
  }) async {
    final id = await client.rpc(
      'create_conversation',
      params: {
        'p_type': isChannel ? 'channel' : 'group',
        'p_title': title,
        'p_description': description,
        'p_avatar_url': avatarUrl,
      },
    ) as String;
    await loadConversations();
    return id;
  }

  /// Creates or returns an existing direct conversation.
  Future<String> createDirect(String peerId) async {
    final id = await client.rpc(
      'create_direct_conversation',
      params: {'p_peer_id': peerId},
    ) as String;
    await loadConversations();
    return id;
  }

  /// Adds a member to a group/channel.
  Future<void> addMember(
    String conversationId,
    String userId, {
    String role = 'member',
  }) async {
    await client.rpc(
      'add_conversation_member',
      params: {
        'p_conversation_id': conversationId,
        'p_user_id': userId,
        'p_role': role,
      },
    );
  }

  /// Removes a member from a group/channel.
  Future<void> removeMember(String conversationId, String userId) async {
    await client.rpc(
      'remove_conversation_member',
      params: {'p_conversation_id': conversationId, 'p_user_id': userId},
    );
  }

  // ========== Messages ==========

  /// Fetches messages for a conversation (paginated, newest first).
  Future<void> loadMessages(String conversationId, {DateTime? before}) async {
    try {
      final result = await client.rpc(
        'fetch_group_messages',
        params: {
          'p_conversation_id': conversationId,
          'p_before': before?.toIso8601String(),
          'p_limit': 50,
        },
      ) as List<dynamic>;

      final messages = result
          .cast<Map<String, dynamic>>()
          .map(GroupMessage.fromJson)
          .toList();

      // Never replace the in-memory thread with a network page. A refresh can
      // race with a send or realtime insert; replacing here would make older
      // messages appear to vanish. Merge by id and keep one stable newest-first
      // ordering: the reversed ListView renders index 0 at the bottom edge.
      final byId = <String, GroupMessage>{
        for (final message in _messages[conversationId] ?? <GroupMessage>[])
          message.id: message,
      };
      for (final message in messages) {
        byId[message.id] = message;
      }
      final merged = byId.values.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      _messages[conversationId] = merged;
      notifyListeners();
    } catch (e) {
      _error = 'Failed to load messages: $e';
      notifyListeners();
    }
  }

  /// Sends a message to a conversation.
  Future<String> sendMessage(
    String conversationId,
    String content, {
    String type = 'text',
    String? parentMessageId,
    String? mediaUrl,
    Map<String, dynamic>? metadata,
    bool isViewOnce = false,
    bool isForwarded = false,
    int forwardCount = 0,
  }) async {
    final id = await client.rpc(
      'send_group_message',
      params: {
        'p_conversation_id': conversationId,
        'p_content': content,
        'p_type': type,
        'p_parent_message_id': parentMessageId,
        'p_media_url': mediaUrl,
        'p_metadata': metadata,
        'p_is_view_once': isViewOnce,
        'p_is_forwarded': isForwarded,
        'p_forward_count': forwardCount,
      },
    ) as String;

    // Add optimistically to local state
    final msg = GroupMessage(
      id: id,
      conversationId: conversationId,
      senderId: _userId,
      content: content,
      type: type,
      createdAt: DateTime.now(),
      parentMessageId: parentMessageId,
      mediaUrl: mediaUrl,
      metadata: metadata,
      isViewOnce: isViewOnce,
      isForwarded: isForwarded,
      forwardCount: forwardCount,
    );

    final existing = _messages[conversationId] ?? <GroupMessage>[];
    if (!existing.any((item) => item.id == msg.id)) {
      _messages[conversationId] = [msg, ...existing];
    }
    notifyListeners();
    return id;
  }

  /// Edits a message (within 15-minute window).
  Future<void> editMessage(String messageId, String newContent) async {
    await client.rpc(
      'edit_group_message',
      params: {'p_message_id': messageId, 'p_content': newContent},
    );
    // Update local state
    for (final messages in _messages.values) {
      final idx = messages.indexWhere((m) => m.id == messageId);
      if (idx >= 0) {
        messages[idx] = GroupMessage(
          id: messages[idx].id,
          conversationId: messages[idx].conversationId,
          senderId: messages[idx].senderId,
          content: newContent,
          type: messages[idx].type,
          createdAt: messages[idx].createdAt,
          senderName: messages[idx].senderName,
          parentMessageId: messages[idx].parentMessageId,
          isEdited: true,
          editedAt: DateTime.now(),
          reactions: messages[idx].reactions,
        );
        break;
      }
    }
    notifyListeners();
  }

  /// Deletes a message.
  Future<void> deleteMessage(
    String messageId, {
    bool forEveryone = false,
  }) async {
    await client.rpc(
      'delete_group_message',
      params: {'p_message_id': messageId, 'p_for_everyone': forEveryone},
    );
    // Update local state
    for (final entry in _messages.entries) {
      final idx = entry.value.indexWhere((m) => m.id == messageId);
      if (idx >= 0) {
        if (forEveryone) {
          entry.value[idx] = GroupMessage(
            id: entry.value[idx].id,
            conversationId: entry.value[idx].conversationId,
            senderId: entry.value[idx].senderId,
            content: 'This message was deleted',
            type: entry.value[idx].type,
            createdAt: entry.value[idx].createdAt,
            isDeleted: true,
          );
        } else {
          entry.value.removeAt(idx);
        }
        break;
      }
    }
    notifyListeners();
  }

  /// Toggles a reaction on a message.
  Future<void> reactToMessage(String messageId, String emoji) async {
    await client.rpc(
      'react_to_message',
      params: {'p_message_id': messageId, 'p_emoji': emoji},
    );
    // Reload messages for the conversation containing this message
    for (final entry in _messages.entries) {
      if (entry.value.any((m) => m.id == messageId)) {
        await loadMessages(entry.key);
        break;
      }
    }
  }

  /// Toggles star on a message.
  Future<void> toggleStar(String messageId) async {
    _starredMessages[_userId] ??= {};
    final starred = _starredMessages[_userId]!;

    if (starred.contains(messageId)) {
      await client
          .from('starred_messages')
          .delete()
          .eq('user_id', _userId)
          .eq('message_id', messageId);
      starred.remove(messageId);
    } else {
      await client.from('starred_messages').insert({
        'user_id': _userId,
        'message_id': messageId,
      });
      starred.add(messageId);
    }
    notifyListeners();
  }

  /// Pins or unpins a message.
  Future<void> togglePin(String conversationId, String messageId) async {
    await client.rpc(
      'pin_message',
      params: {'p_conversation_id': conversationId, 'p_message_id': messageId},
    );
    await loadMessages(conversationId);
  }

  // ========== Presence ==========

  /// Updates online/offline status and custom status.
  Future<void> updatePresence({
    required bool isOnline,
    String? customStatus,
  }) async {
    try {
      await client.rpc(
        'update_presence',
        params: {'p_is_online': isOnline, 'p_custom_status': customStatus},
      );
    } catch (_) {
      // Non-critical; don't block the UI
    }
  }

  // ========== Realtime subscription ==========

  StreamSubscription? _realtimeSub;

  /// Subscribes to realtime inserts on group_messages for a conversation.
  void subscribeToConversation(String conversationId) {
    _realtimeSub?.cancel();

    final channel = client.channel('group:$conversationId');
    channel
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'group_messages',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'conversation_id',
          value: conversationId,
        ),
        callback: (payload) {
          final record = payload.newRecord;
          final msg = GroupMessage.fromJson(record);
          if (msg.senderId == _userId) return; // Skip own echoes

          if ((_messages[conversationId] ?? const <GroupMessage>[]).any(
            (item) => item.id == msg.id,
          )) {
            return;
          }

          _messages[conversationId] = [
            msg,
            ...(_messages[conversationId] ?? []),
          ];
          notifyListeners();
        },
      )
      ..subscribe();
  }

  void unsubscribeFromConversation() {
    _realtimeSub?.cancel();
    _realtimeSub = null;
  }

  @override
  void dispose() {
    _realtimeSub?.cancel();
    super.dispose();
  }
}
