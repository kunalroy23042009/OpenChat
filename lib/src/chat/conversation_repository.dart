import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../ops/error_report.dart';
import '../security/secure_history_database.dart';
import '../security/signal_crypto.dart';

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
    this.isLocked = false,
    this.isFavourite = false,
    this.markedUnread = false,
    this.mutedUntilMs,
    this.unreadCount = 0,
    this.memberCount = 0,
    this.lastActivity,
    this.lastMessage,
    this.isArchivedBackup = false,
    this.e2eeEnabled = false,
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
  final bool isLocked;
  final bool isFavourite;
  final bool markedUnread;
  final int? mutedUntilMs;
  final int unreadCount;
  final int memberCount;
  final DateTime? lastActivity;
  final String? lastMessage;
  final bool isArchivedBackup;
  final bool e2eeEnabled;

  bool get isGroup => type == 'group';
  bool get isChannel => type == 'channel';
  bool get isAdmin => myRole == 'admin' || myRole == 'owner';
  bool get isOwner => myRole == 'owner';
  bool get isMutedNow =>
      isMuted &&
      (mutedUntilMs == null ||
          DateTime.now().millisecondsSinceEpoch < mutedUntilMs!);

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
        isLocked: json['is_locked'] as bool? ?? false,
        isFavourite: json['is_favourite'] as bool? ?? false,
        markedUnread: json['marked_unread'] as bool? ?? false,
        mutedUntilMs: json['muted_until'] != null
            ? DateTime.tryParse(json['muted_until'] as String)
                  ?.millisecondsSinceEpoch
            : null,
        unreadCount: json['unread_count'] as int? ?? 0,
        memberCount: json['member_count'] as int? ?? 0,
        lastActivity: json['last_activity'] != null
            ? DateTime.tryParse(json['last_activity'] as String)
            : null,
        lastMessage: json['last_message'] as String?,
        isArchivedBackup: json['is_archived_backup'] as bool? ?? false,
        e2eeEnabled: json['e2ee_enabled'] as bool? ?? false,
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
    this.senderAvatar,
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
    this.isPending = false,
    this.pendingCiphertext,
    this.encryptionEpoch,
  });

  final String id;
  final String conversationId;
  final String senderId;
  final String content;
  final String type;
  final DateTime createdAt;
  final String? senderName;
  final String? senderAvatar;
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
  final bool isPending;
  final String? pendingCiphertext;
  final int? encryptionEpoch;

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
    senderAvatar:
        json['sender_avatar'] as String? ?? json['avatar_url'] as String?,
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
    isPending: json['is_pending'] as bool? ?? false,
    pendingCiphertext: json['pending_ciphertext'] as String?,
    encryptionEpoch: (json['e2ee_epoch'] as num?)?.toInt(),
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
  ConversationRepository(
    this.client, {
    this.secureHistory,
    this.archiveConversation,
  });

  final SupabaseClient client;
  final SecureHistoryDatabase? secureHistory;
  final Map<String, dynamic>? archiveConversation;
  static const _signalChannel = MethodChannel('dev.openchat/security');
  List<GroupConversation> _conversations = [];
  final Map<String, List<GroupMessage>> _messages = {};
  final Map<String, Set<String>> _starredMessages = {};
  final Map<String, List<TeamTask>> _tasks = {};
  final Map<String, Future<Map<String, dynamic>>> _groupDecryptInFlight = {};
  final Map<String, Map<String, dynamic>> _decryptedGroupRows = {};
  final Map<String, Future<void>> _groupDecryptQueues = {};
  bool _loading = false;
  String? _error;

  List<GroupConversation> get conversations => _conversations;
  bool get loading => _loading;
  String? get error => _error;

  String get _userId => client.auth.currentUser!.id;

  Future<String?> _profileAvatarUrl(String? path, [String? legacyUrl]) async {
    if (path == null || path.isEmpty) return legacyUrl;
    try {
      return await client.storage
          .from('profile-avatars')
          .createSignedUrl(path, 60 * 60);
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> _withAvatarUrl(Map<String, dynamic> row) async {
    final copy = Map<String, dynamic>.from(row);
    final path = (copy['sender_avatar_path'] ?? copy['avatar_path']) as String?;
    final legacy = (copy['sender_avatar'] ?? copy['avatar_url']) as String?;
    final url = await _profileAvatarUrl(path, legacy);
    if (copy.containsKey('sender_avatar_path') ||
        copy.containsKey('sender_avatar')) {
      copy['sender_avatar'] = url;
    } else {
      copy['avatar_url'] = url;
    }
    return copy;
  }

  List<GroupMessage> messagesFor(String conversationId) =>
      _messages[conversationId] ?? [];

  List<TeamTask> tasksFor(String conversationId) =>
      _tasks[conversationId] ?? const [];

  List<GroupConversation> _recoveredConversations() {
    final uid = client.auth.currentUser?.id;
    if (uid == null || secureHistory == null) return [];
    final recovered = <GroupConversation>[];
    for (final encoded
        in secureHistory!
            .readEntries('openchat.groupArchive.v1.$uid.')
            .values) {
      try {
        final archive = Map<String, dynamic>.from(jsonDecode(encoded) as Map);
        final conversation = Map<String, dynamic>.from(
          archive['conversation'] as Map,
        )..['is_archived_backup'] = true;
        recovered.add(GroupConversation.fromJson(conversation));
      } catch (_) {
        // Keep damaged archive bytes untouched and hide this entry.
      }
    }
    return recovered;
  }

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
    final security = await _groupSecurityState(conversationId);
    if (security['e2ee_enabled'] == true) {
      throw StateError('Tasks are not supported in encrypted groups yet.');
    }
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
    final security = await _groupSecurityState(conversationId);
    if (security['e2ee_enabled'] == true) {
      throw StateError('Polls are not supported in encrypted groups yet.');
    }
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

      final conversations = result
          .cast<Map<String, dynamic>>()
          .map(GroupConversation.fromJson)
          .toList();
      final knownIds = {for (final c in conversations) c.id};
      final uid = client.auth.currentUser?.id;
      if (uid != null && secureHistory != null) {
        for (final encoded
            in secureHistory!
                .readEntries('openchat.groupArchive.v1.$uid.')
                .values) {
          try {
            final archive = Map<String, dynamic>.from(
              jsonDecode(encoded) as Map,
            );
            final raw = Map<String, dynamic>.from(
              archive['conversation'] as Map,
            );
            final id = raw['id'] as String?;
            if (id == null || knownIds.contains(id)) continue;
            raw['is_archived_backup'] = true;
            conversations.add(GroupConversation.fromJson(raw));
            knownIds.add(id);
          } catch (_) {
            // A damaged archive stays stored, but is not shown as a chat.
          }
        }
      }
      _conversations = conversations
        ..sort((a, b) {
          if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
          return (b.lastActivity ?? b.createdAt ?? DateTime(1970)).compareTo(
            a.lastActivity ?? a.createdAt ?? DateTime(1970),
          );
        });
    } catch (e) {
      _conversations = _recoveredConversations();
      _error = _conversations.isEmpty
          ? 'Failed to load conversations: $e'
          : null;
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

  /// Promotes ('admin') or demotes ('member') a group member.
  Future<void> setMemberRole(
    String conversationId,
    String userId,
    String role,
  ) async {
    await client.rpc(
      'set_conversation_member_role',
      params: {
        'p_conversation_id': conversationId,
        'p_user_id': userId,
        'p_role': role,
      },
    );
  }

  /// Updates group settings (title/description/photo). Admins/owners only.
  Future<void> updateConversation(
    String conversationId, {
    String? title,
    String? description,
    String? avatarUrl,
  }) async {
    await client.rpc(
      'update_conversation',
      params: {
        'p_conversation_id': conversationId,
        'p_title': title,
        'p_description': description,
        'p_avatar_url': avatarUrl,
      },
    );
    await loadConversations();
  }

  /// Gets the group invite code (creates if missing).
  Future<String> getGroupInviteCode(String conversationId) async {
    final result = await client.rpc(
      'group_invite_link',
      params: {'p_conversation_id': conversationId, 'p_reset': false},
    ) as String;
    return result;
  }

  /// Resets the group invite code.
  Future<String> resetGroupInviteCode(String conversationId) async {
    final result = await client.rpc(
      'group_invite_link',
      params: {'p_conversation_id': conversationId, 'p_reset': true},
    ) as String;
    return result;
  }

  /// Previews a group invite by code (without joining).
  Future<Map<String, dynamic>> previewGroupInvite(String code) async {
    final result = await client.rpc(
      'preview_group_invite',
      params: {'p_code': code},
    ) as Map<String, dynamic>;
    return result;
  }

  /// Joins a group by invite code.
  Future<String> joinGroupByInvite(String code) async {
    final result = await client.rpc(
      'join_group_by_invite',
      params: {'p_code': code},
    ) as String;
    await loadConversations();
    return result;
  }

  /// Permanently deletes a group and its server-owned data. Owner-only RPC.
  Future<void> deleteGroup(String conversationId) async {
    await client.rpc(
      'delete_conversation_group',
      params: {'p_conversation_id': conversationId},
    );
    _conversations = _conversations
        .where((conversation) => conversation.id != conversationId)
        .toList();
    notifyListeners();
  }

  /// Transfers group ownership to an existing member. Owner-only RPC.
  Future<void> transferOwnership(
    String conversationId,
    String newOwnerId,
  ) async {
    await client.rpc(
      'transfer_conversation_ownership',
      params: {
        'p_conversation_id': conversationId,
        'p_new_owner_id': newOwnerId,
      },
    );
    await loadConversations();
  }

  /// Roster with roles for the member sheet. Caller must belong to the
  /// conversation; each row carries user_id, role, display_name, username.
  Future<List<Map<String, dynamic>>> members(String conversationId) async {
    final rows = await client.rpc(
      'list_conversation_members',
      params: {'p_conversation_id': conversationId},
    ) as List;
    return Future.wait(
      rows.map((row) => _withAvatarUrl(Map<String, dynamic>.from(row as Map))),
    );
  }

  /// Current votes for a group poll message.
  Future<List<Map<String, dynamic>>> pollVotes(String messageId) async {
    final rows = await client
        .from('poll_votes')
        .select('option_index, user_id')
        .eq('message_id', messageId);
    return (rows as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
  }

  /// Marks group messages as read up to the given timestamp.
  Future<void> markGroupRead(String conversationId, DateTime readAt) async {
    await client.rpc(
      'mark_group_read',
      params: {
        'p_conversation_id': conversationId,
        'p_read_at': readAt.toUtc().toIso8601String(),
      },
    );
  }

  /// Notifies server to send FCM nudges to other group members.
  Future<void> notifyGroup(String conversationId, String messageId) async {
    await client.functions.invoke(
      'notify-send',
      body: {'kind': 'group', 'group': conversationId, 'event': messageId},
    );
  }

  /// Updates per-member conversation flags (mute/pin/archive/lock/favourite).
  /// Only non-null arguments are applied.
  Future<void> setConversationFlags(
    String conversationId, {
    bool? muted,
    DateTime? mutedUntil,
    bool? pinned,
    bool? archived,
    bool? locked,
    bool? favourite,
    bool? markedUnread,
  }) async {
    await client.rpc(
      'set_conversation_member_flags',
      params: {
        'p_conversation_id': conversationId,
        'p_is_muted': muted,
        'p_muted_until': mutedUntil?.toUtc().toIso8601String(),
        'p_is_pinned': pinned,
        'p_is_archived': archived,
        'p_is_locked': locked,
        'p_is_favourite': favourite,
        'p_marked_unread': markedUnread,
      },
    );
    await loadConversations();
  }

  // ========== Messages ==========

  /// Fetches messages for a conversation (paginated, newest first).
  static const messagePageSize = 50;

  String _groupArchiveKey(String uid, String conversationId) =>
      'openchat.groupArchive.v1.$uid.$conversationId';

  Future<Map<String, dynamic>> _groupSecurityState(
    String conversationId,
  ) async => Map<String, dynamic>.from(
    await client.rpc(
      'group_security_state',
      params: {'p_conversation_id': conversationId},
    ) as Map,
  );

  Future<void> _processSenderKeyQueue(
    String conversationId,
    SharedPreferences preferences,
  ) async {
    final uid = client.auth.currentUser?.id;
    if (uid == null) throw StateError('Sign in to open this encrypted group.');
    final crypto = SignalCrypto(
      client: client,
      accountId: uid,
      preferences: preferences,
    );
    while (true) {
      final rows = await client.rpc(
        'fetch_group_sender_keys',
        params: {'p_conversation_id': conversationId, 'p_limit': 100},
      ) as List<dynamic>;
      if (rows.isEmpty) return;
      final acknowledged = <String>[];
      for (final raw in rows.cast<Map<String, dynamic>>()) {
        final id = raw['id'] as String?;
        if (id == null || id.isEmpty) continue;
        final senderId = raw['sender_id'] as String;
        final epoch = (raw['epoch'] as num).toInt();
        final distribution = await crypto.decryptText(
          senderId,
          raw['ciphertext'] as String,
        );
        await _signalChannel.invokeMethod('signalGroupProcess', {
          'accountId': uid,
          'groupId': conversationId,
          'epoch': epoch,
          'senderId': senderId,
          'distribution': distribution,
        });
        acknowledged.add(id);
      }
      if (acknowledged.isEmpty) {
        throw StateError(
          'Encrypted group key queue could not be acknowledged.',
        );
      }
      await client.rpc(
        'ack_group_sender_keys',
        params: {'p_ids': acknowledged},
      );
    }
  }

  Future<Map<String, dynamic>> _decryptGroupRow(
    String uid,
    Map<String, dynamic> row, {
    bool throwOnFailure = false,
  }) async {
    final content = row['content'] as String? ?? '';
    final metadata = row['metadata'] as Map<String, dynamic>? ?? const {};
    if (metadata['e2ee'] != true || !content.startsWith('E2E1:')) return row;
    // Ratchets reject replay after restart. Reuse the durably decrypted body,
    // while retaining current server receipts, deletion state and reactions.
    final archive = secureHistory?.read(
      _groupArchiveKey(uid, row['conversation_id'] as String),
    );
    if (archive != null) {
      final saved = jsonDecode(archive) as Map;
      for (final raw in saved['messages'] as List? ?? []) {
        final local = Map<String, dynamic>.from(raw as Map);
        if (local['id'] == row['id'] &&
            local['sender_id'] == row['sender_id'] &&
            local['content'] !=
                'Could not decrypt this group message on this device.' &&
            !(local['content'] as String).startsWith('E2E1:')) {
          return {
            ...row,
            'content': local['content'],
            'type': local['type'],
            'parent_message_id': local['parent_message_id'],
            'metadata': local['metadata'],
            'e2ee_epoch': metadata['epoch'],
            'is_pending': false,
          };
        }
      }
    }
    final cacheKey = '${row['conversation_id']}:${row['id']}';
    final cached = _decryptedGroupRows[cacheKey];
    if (cached != null) return {...row, ...cached};
    final inFlight = _groupDecryptInFlight[cacheKey];
    if (inFlight != null) return {...row, ...await inFlight};
    final future = _decryptGroupRowSequentially(
      uid,
      row,
      throwOnFailure: throwOnFailure,
    );
    _groupDecryptInFlight[cacheKey] = future;
    try {
      final decrypted = await future;
      if (decrypted['content'] !=
          'Could not decrypt this group message on this device.') {
        _decryptedGroupRows[cacheKey] = decrypted;
      }
      return decrypted;
    } finally {
      if (identical(_groupDecryptInFlight[cacheKey], future)) {
        _groupDecryptInFlight.remove(cacheKey);
      }
    }
  }

  Future<Map<String, dynamic>> _decryptGroupRowSequentially(
    String uid,
    Map<String, dynamic> row, {
    required bool throwOnFailure,
  }) async {
    final conversationId = row['conversation_id'] as String;
    final previous =
        _groupDecryptQueues[conversationId] ?? Future<void>.value();
    final gate = Completer<void>();
    _groupDecryptQueues[conversationId] = gate.future;
    try {
      await previous.catchError((_) {});
      return await _decryptGroupRowOnce(
        uid,
        row,
        throwOnFailure: throwOnFailure,
      );
    } finally {
      gate.complete();
      if (identical(_groupDecryptQueues[conversationId], gate.future)) {
        _groupDecryptQueues.remove(conversationId);
      }
    }
  }

  Future<Map<String, dynamic>> _decryptGroupRowOnce(
    String uid,
    Map<String, dynamic> row, {
    required bool throwOnFailure,
  }) async {
    final content = row['content'] as String? ?? '';
    final metadata = row['metadata'] as Map<String, dynamic>? ?? const {};
    if (metadata['e2ee'] != true || !content.startsWith('E2E1:')) return row;
    final epoch = (metadata['epoch'] as num).toInt();
    try {
      final result = await _signalChannel.invokeMapMethod<String, dynamic>(
        'signalGroupDecrypt',
        {
          'accountId': uid,
          'groupId': row['conversation_id'],
          'epoch': epoch,
          'senderId': row['sender_id'],
          'ciphertext': content.substring(5),
        },
      );
      final plain = result?['plain'] as String?;
      if (plain == null) throw StateError('Missing decrypted group message.');
      final decoded = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(base64Decode(plain))) as Map,
      );
      return {
        ...row,
        ...decoded,
        'id': row['id'],
        'conversation_id': row['conversation_id'],
        'sender_id': row['sender_id'],
        'sender_name': row['sender_name'],
        'created_at': row['created_at'],
        'reactions': row['reactions'],
        'is_pinned': row['is_pinned'],
        'is_starred': row['is_starred'],
        'is_edited': row['is_edited'],
        'edited_at': row['edited_at'],
        'is_deleted': row['is_deleted'],
        'is_view_once': false,
        'is_forwarded': false,
        'forward_count': 0,
        'metadata': decoded['metadata'] ?? const <String, dynamic>{},
        'e2ee_epoch': epoch,
        'is_pending': false,
      };
    } catch (error) {
      // Never show raw ciphertext as if it were a readable chat message.
      if (throwOnFailure) {
        throw StateError(
          'Could not decrypt a group message for backup: $error',
        );
      }
      return {
        ...row,
        'content': 'Could not decrypt this group message on this device.',
        'type': 'text',
        'media_url': null,
        'metadata': const <String, dynamic>{},
      };
    }
  }

  Map<String, dynamic> _archiveJson(GroupMessage message) => {
    'id': message.id,
    'conversation_id': message.conversationId,
    'sender_id': message.senderId,
    'sender_name': message.senderName,
    'parent_message_id': message.parentMessageId,
    'content': message.content,
    'type': message.type,
    'media_url': message.mediaUrl,
    'metadata': message.metadata,
    'is_edited': message.isEdited,
    'edited_at': message.editedAt?.toIso8601String(),
    'is_deleted': message.isDeleted,
    'is_view_once': message.isViewOnce,
    'is_forwarded': message.isForwarded,
    'forward_count': message.forwardCount,
    'is_pinned': message.isPinned,
    'is_starred': message.isStarred,
    'is_pending': message.isPending,
    'pending_ciphertext': message.pendingCiphertext,
    'e2ee_epoch': message.encryptionEpoch,
    'reactions': message.reactions
        .map(
          (reaction) => {'emoji': reaction.emoji, 'user_id': reaction.userId},
        )
        .toList(),
    'created_at': message.createdAt.toUtc().toIso8601String(),
  };

  Future<void> _persistGroupArchive(
    String uid,
    String conversationId,
    Iterable<GroupMessage> messages,
  ) async {
    final history = secureHistory;
    if (history == null) return;
    final key = _groupArchiveKey(uid, conversationId);
    final existingRaw = history.read(key);
    final existing = existingRaw == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(existingRaw) as Map);
    final byId = <String, Map<String, dynamic>>{
      for (final raw in (existing['messages'] as List? ?? []))
        (raw as Map)['id'] as String: Map<String, dynamic>.from(raw),
    };
    for (final message in messages) {
      final next = _archiveJson(message);
      final prev = byId[message.id];
      if (prev == null) {
        byId[message.id] = next;
        continue;
      }
      final prevContent = prev['content'] as String? ?? '';
      final nextContent = next['content'] as String? ?? '';
      final prevBad =
          prevContent == 'Could not decrypt this group message on this device.';
      final nextBad =
          nextContent == 'Could not decrypt this group message on this device.';
      final prevPending = prev['is_pending'] == true;
      final nextPending = next['is_pending'] == true;
      // Never replace good decrypted history with a placeholder, and prefer
      // confirmed server rows over local pending outbox rows.
      if (!prevBad && nextBad) continue;
      if (!prevPending && nextPending) continue;
      if (prevBad && !nextBad) {
        byId[message.id] = next;
        continue;
      }
      if (prevPending && !nextPending) {
        byId[message.id] = next;
        continue;
      }
      // Otherwise keep the newest write; timestamps decide final sort order.
      byId[message.id] = next;
    }
    final conversation =
        archiveConversation ??
        Map<String, dynamic>.from(
          existing['conversation'] as Map? ??
              {'id': conversationId, 'type': 'group'},
        );
    await history.write(
      key,
      jsonEncode({
        'conversation': conversation,
        'messages': byId.values.toList()
          ..sort(
            (a, b) => (a['created_at'] as String).compareTo(
              b['created_at'] as String,
            ),
          ),
      }),
    );
  }

  /// Produces a full member-visible export for the password-encrypted cloud
  /// backup. E2EE rows are decrypted locally in chronological Signal order;
  /// an incomplete key/history set makes backup fail instead of silently
  /// producing an unusable archive.
  Future<Map<String, dynamic>> exportGroupBackup() async {
    final conversations = <Map<String, dynamic>>[];
    for (var offset = 0; ; offset += 100) {
      final result = await client.rpc(
        'list_conversations',
        params: {'p_limit': 100, 'p_offset': offset},
      ) as List<dynamic>;
      conversations.addAll(
        result.cast<Map<String, dynamic>>().where(
          (row) => row['type'] == 'group' || row['type'] == 'channel',
        ),
      );
      if (result.length < 100) break;
    }

    final exported = <String, dynamic>{};
    final uid = _userId;
    for (final conversation in conversations) {
      final conversationId = conversation['id'] as String;
      final encrypted = conversation['e2ee_enabled'] == true;
      if (encrypted) {
        await _processSenderKeyQueue(
          conversationId,
          await SharedPreferences.getInstance(),
        );
      }
      final serverRows = <Map<String, dynamic>>[];
      DateTime? before;
      String? beforeId;
      while (true) {
        final page = await client.rpc(
          'backup_group_messages',
          params: {
            'p_conversation_id': conversationId,
            'p_before': before?.toIso8601String(),
            'p_before_id': beforeId,
            'p_limit': 100,
          },
        ) as List<dynamic>;
        final mapped = page
            .cast<Map<String, dynamic>>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList();
        serverRows.addAll(mapped);
        if (page.length < 100) break;
        before = DateTime.parse(mapped.first['created_at'] as String);
        beforeId = mapped.first['id'] as String;
      }
      serverRows.sort((a, b) {
        final time = (a['created_at'] as String).compareTo(
          b['created_at'] as String,
        );
        return time == 0
            ? (a['id'] as String).compareTo(b['id'] as String)
            : time;
      });

      final localRows = <String, Map<String, dynamic>>{};
      final localArchive = secureHistory?.read(
        _groupArchiveKey(uid, conversationId),
      );
      if (localArchive != null) {
        final archive = Map<String, dynamic>.from(
          jsonDecode(localArchive) as Map,
        );
        for (final row in (archive['messages'] as List? ?? [])) {
          final mapped = Map<String, dynamic>.from(row as Map);
          localRows[mapped['id'] as String] = mapped;
        }
      }

      final messages = <Map<String, dynamic>>[];
      for (final row in serverRows) {
        final local = localRows.remove(row['id']);
        if (row['is_deleted'] == true) {
          messages.add(row);
        } else if (local != null &&
            local['content'] !=
                'Could not decrypt this group message on this device.') {
          messages.add(local);
        } else if ((row['metadata'] as Map?)?['e2ee'] == true) {
          messages.add(await _decryptGroupRow(uid, row, throwOnFailure: true));
        } else {
          messages.add(row);
        }
      }
      messages.addAll(localRows.values);
      messages.sort((a, b) {
        final time = (a['created_at'] as String).compareTo(
          b['created_at'] as String,
        );
        return time == 0
            ? (a['id'] as String).compareTo(b['id'] as String)
            : time;
      });
      exported[conversationId] = {
        'conversation': conversation,
        'messages': messages,
      };
    }
    return exported;
  }

  Future<int> loadMessages(String conversationId, {DateTime? before}) async {
    try {
      final result = await client.rpc(
        'fetch_group_messages',
        params: {
          'p_conversation_id': conversationId,
          'p_before': before?.toIso8601String(),
          'p_limit': messagePageSize,
        },
      ) as List<dynamic>;

      final uid = client.auth.currentUser?.id;
      var messageRows = await Future.wait(
        result.cast<Map<String, dynamic>>().map((row) => _withAvatarUrl(row)),
      );
      final isEncrypted = messageRows.any(
        (row) => (row['metadata'] as Map?)?['e2ee'] == true,
      );
      if (isEncrypted && uid != null) {
        await _processSenderKeyQueue(
          conversationId,
          await SharedPreferences.getInstance(),
        );
        // Ensure our own sender key for the CURRENT epoch is distributed
        // even if we never send. After a reinstall the server advanced the
        // group's epoch; until each member re-distributes, their new rows
        // render as "could not decrypt" placeholders on this device.
        final security = await _ensureGroupSenderKeyReady(conversationId);
        final decryptedRows = <Map<String, dynamic>>[];
        // Signal sender-key chains are stateful; decrypt in server order.
        var placeholderRows = 0;
        for (final row in messageRows) {
          final decrypted = await _decryptGroupRow(uid, row);
          if ((decrypted['content'] as String? ?? '').startsWith('Could')
              && security != null) {
            placeholderRows++;
          }
          decryptedRows.add(decrypted);
        }
        // Stale acknowledged distributions: if several current-epoch rows
        // fail and some deliveries were already acknowledged from a lost
        // session, re-issue them once and retry a single bounded pass.
        if (placeholderRows >= 3 && security != null) {
          final currentEpoch = (security['epoch'] as num).toInt();
          final cannotDecryptAtCurrentEpoch = decryptedRows.any(
            (row) =>
                (row['content'] as String? ?? '').startsWith('Could') &&
                _rowE2eeEpoch(row) == currentEpoch,
          );
          if (cannotDecryptAtCurrentEpoch) {
            try {
              final reissued = await client.rpc(
                'reissue_group_sender_keys',
                params: {'p_conversation_id': conversationId},
              );
              if (reissued is num && reissued.toInt() > 0) {
                await _processSenderKeyQueue(
                  conversationId,
                  await SharedPreferences.getInstance(),
                );
                for (var i = 0; i < decryptedRows.length; i++) {
                  final row = decryptedRows[i];
                  if ((row['content'] as String? ?? '')
                      .startsWith('Could')) {
                    decryptedRows[i] = await _decryptGroupRow(uid, row);
                  }
                }
              }
            } catch (e) {
              ErrorReport.reportError('group-keys', e, code: 'reissue');
            }
          }
        }
        messageRows = decryptedRows;
      }
      if (uid != null && before == null && secureHistory != null) {
        final archiveKey = 'openchat.groupArchive.v1.$uid.$conversationId';
        final archive = secureHistory!.read(archiveKey);
        if (archive != null) {
          final saved = Map<String, dynamic>.from(jsonDecode(archive) as Map);
          final fetchedIds = {for (final row in messageRows) row['id']};
          messageRows.addAll(
            (saved['messages'] as List? ?? [])
                .map((row) => Map<String, dynamic>.from(row as Map))
                .where((row) => !fetchedIds.contains(row['id'])),
          );
        }
      }
      final messages = messageRows.map(GroupMessage.fromJson).toList();
      if (isEncrypted && uid != null) {
        await _persistGroupArchive(uid, conversationId, messages);
      }

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
      return result.length;
    } catch (e) {
      final uid = client.auth.currentUser?.id;
      final archive = uid == null || secureHistory == null || before != null
          ? null
          : secureHistory!.read(
              'openchat.groupArchive.v1.$uid.$conversationId',
            );
      if (archive != null) {
        try {
          final saved = Map<String, dynamic>.from(jsonDecode(archive) as Map);
          final archivedMessages =
              (saved['messages'] as List? ?? [])
                  .map(
                    (row) => GroupMessage.fromJson(
                      Map<String, dynamic>.from(row as Map),
                    ),
                  )
                  .toList()
                ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
          _messages[conversationId] = archivedMessages;
          _error = null;
          notifyListeners();
          return 0;
        } catch (_) {
          // Fall through to the original network error without modifying the
          // encrypted archive.
        }
      }
      _error = 'Failed to load messages: $e';
      notifyListeners();
      rethrow;
    }
  }

  /// Sends a message to a conversation.
  String _newMessageId() {
    final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// Epoch stamped on a group row's metadata (null when unknown; older
  /// rows may not carry it — the sender-key envelope queue resolves
  /// history epochs independently).
  static int? _rowE2eeEpoch(Map<String, dynamic> row) {
    final metadata = row['metadata'];
    if (metadata is Map) {
      final value = metadata['epoch'];
      if (value is num) return value.toInt();
    }
    return null;
  }

  /// Makes sure this device holds and has distributed a sender key for the
  /// conversation's CURRENT epoch. Called both from the send path and from
  /// message loading — after a reinstall, the server advanced the epoch but
  /// members only re-distribute keys when they next send; until then every
  /// row decrypts to "could not decrypt" placeholders. Never throws on the
  /// (optional) load path: returns the fetched security state, or null when
  /// the group is not encrypted or the broker is unreachable.
  Future<Map<String, dynamic>?> _ensureGroupSenderKeyReady(
    String conversationId, {
    Map<String, dynamic>? preloadedState,
  }) async {
    Map<String, dynamic> securityState;
    try {
      securityState = preloadedState ??
          await _groupSecurityState(conversationId);
    } catch (e) {
      ErrorReport.reportError('group-keys', e, code: 'security_state');
      return null;
    }
    if (securityState['e2ee_enabled'] != true) return null;
    final uid = _userId;
    final epoch = (securityState['epoch'] as num).toInt();
    final memberIds = (securityState['member_ids'] as List)
        .map((value) => value.toString())
        .toList();
    if (!memberIds.contains(uid)) return null;

    try {
      final sender = await _signalChannel.invokeMapMethod<String, dynamic>(
        'signalGroupCreate',
        {'accountId': uid, 'groupId': conversationId, 'epoch': epoch},
      );
      if (sender == null) return null;
      if (sender['created'] == true) {
        final distribution = sender['distribution'] as String;
        final crypto = SignalCrypto(
          client: client,
          accountId: uid,
          preferences: await SharedPreferences.getInstance(),
        );
        final envelopes = <String, String>{};
        for (final peerId in memberIds.where((id) => id != uid)) {
          try {
            envelopes[peerId] = await crypto.encryptText(peerId, distribution);
          } catch (e) {
            // One unreachable/corrupt peer must not starve the rest of the
            // group: skip them; they heal via key re-issue on their side.
            ErrorReport.report(
              area: 'group-keys',
              code: 'distribute_peer_skipped',
              details: {'peer_sha': peerId.hashCode.toRadixString(36)},
            );
          }
        }
        if (envelopes.isEmpty) {
          throw StateError('No member could receive the sender key.');
        }
        await client.rpc(
          'publish_group_sender_key',
          params: {
            'p_conversation_id': conversationId,
            'p_epoch': epoch,
            'p_distribution_id': sender['distributionId'],
            'p_envelopes': envelopes,
          },
        );
        await _signalChannel.invokeMethod('signalGroupMarkPublished', {
          'accountId': uid,
          'groupId': conversationId,
          'epoch': epoch,
        });
      }
      return securityState;
    } catch (e) {
      ErrorReport.reportError('group-keys', e, code: 'distribute');
      return null;
    }
  }

  Future<String> _sendEncryptedGroupMessage(
    String conversationId,
    String content,
    Map<String, dynamic> securityState, {
    String? parentMessageId,
  }) async {
    if (securityState['e2ee_enabled'] != true) {
      throw StateError('Encrypted group mode is not enabled.');
    }
    if (content.trim().isEmpty || content.length > 3500) {
      throw ArgumentError('Encrypted group text must be 1–3500 characters.');
    }
    final uid = _userId;
    final epoch = (securityState['epoch'] as num).toInt();
    final memberIds = (securityState['member_ids'] as List)
        .map((value) => value.toString())
        .toList();
    if (!memberIds.contains(uid)) throw StateError('Group membership changed.');

    // Create and publish (or reuse) this device's sender key for the epoch.
    final readyState = await _ensureGroupSenderKeyReady(
      conversationId,
      preloadedState: securityState,
    );
    if (readyState == null) {
      // Recipients need the distribution before they can decrypt a message.
      ErrorReport.report(
        area: 'group-keys',
        code: 'send_distribution_pending',
        details: {'epoch': '$epoch'},
      );
      throw StateError('Group encryption keys could not be shared. Try again.');
    }

    final messageId = _newMessageId();
    final clearPayload = jsonEncode({
      'content': content,
      'type': 'text',
      'parent_message_id': parentMessageId,
    });
    final sealed = await _signalChannel.invokeMapMethod<String, dynamic>(
      'signalGroupEncrypt',
      {
        'accountId': uid,
        'groupId': conversationId,
        'epoch': epoch,
        'plain': base64Encode(utf8.encode(clearPayload)),
      },
    );
    if (sealed == null) throw StateError('Could not encrypt group message.');
    final ciphertext = sealed['ciphertext'] as String;
    var message = GroupMessage(
      id: messageId,
      conversationId: conversationId,
      senderId: uid,
      content: content,
      type: 'text',
      createdAt: DateTime.now(),
      parentMessageId: parentMessageId,
      metadata: const {'e2ee': true},
      isPending: true,
      pendingCiphertext: ciphertext,
      encryptionEpoch: epoch,
    );
    _upsertLocalGroupMessage(conversationId, message);
    await _persistGroupArchive(uid, conversationId, _messages[conversationId]!);
    notifyListeners();

    await _transmitPendingGroupMessage(message);
    message = _messageWithPending(message, false);
    _upsertLocalGroupMessage(conversationId, message);
    await _persistGroupArchive(uid, conversationId, _messages[conversationId]!);
    notifyListeners();
    return messageId;
  }

  void _upsertLocalGroupMessage(String conversationId, GroupMessage message) {
    _messages[conversationId] = [
      message,
      ...(_messages[conversationId] ?? const <GroupMessage>[]).where(
        (existing) => existing.id != message.id,
      ),
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  GroupMessage _messageWithPending(GroupMessage message, bool pending) =>
      GroupMessage(
        id: message.id,
        conversationId: message.conversationId,
        senderId: message.senderId,
        content: message.content,
        type: message.type,
        createdAt: message.createdAt,
        senderName: message.senderName,
        parentMessageId: message.parentMessageId,
        mediaUrl: message.mediaUrl,
        metadata: message.metadata,
        isEdited: message.isEdited,
        editedAt: message.editedAt,
        isDeleted: message.isDeleted,
        isViewOnce: message.isViewOnce,
        isForwarded: message.isForwarded,
        forwardCount: message.forwardCount,
        reactions: message.reactions,
        isPinned: message.isPinned,
        isStarred: message.isStarred,
        isPending: pending,
        pendingCiphertext: pending ? message.pendingCiphertext : null,
        encryptionEpoch: message.encryptionEpoch,
      );

  Future<void> _transmitPendingGroupMessage(GroupMessage message) async {
    final ciphertext = message.pendingCiphertext;
    final epoch = message.encryptionEpoch;
    if (ciphertext == null || epoch == null) {
      throw StateError('Encrypted group outbox record is incomplete.');
    }
    await client.rpc(
      'send_e2ee_group_message',
      params: {
        'p_conversation_id': message.conversationId,
        'p_message_id': message.id,
        'p_epoch': epoch,
        'p_ciphertext': ciphertext,
      },
    );
  }

  /// Retries encrypted group outbox rows with the same id and ciphertext.
  /// Server idempotency makes an ACK-lost retry safe and duplicate-free.
  Future<void> retryPendingGroupMessages(String conversationId) async {
    final uid = client.auth.currentUser?.id;
    final history = secureHistory;
    if (uid == null || history == null) return;
    final key = _groupArchiveKey(uid, conversationId);
    final encoded = history.read(key);
    if (encoded == null) return;
    final archive = Map<String, dynamic>.from(jsonDecode(encoded) as Map);
    final messages = (archive['messages'] as List? ?? [])
        .map(
          (raw) => GroupMessage.fromJson(Map<String, dynamic>.from(raw as Map)),
        )
        .toList();
    if (messages.every((message) => !message.isPending)) return;
    final state = await _groupSecurityState(conversationId);
    if (state['e2ee_enabled'] != true) return;
    final epoch = (state['epoch'] as num).toInt();
    var changed = false;
    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      if (!message.isPending || message.encryptionEpoch != epoch) continue;
      try {
        await _transmitPendingGroupMessage(message);
        messages[i] = _messageWithPending(message, false);
        _upsertLocalGroupMessage(conversationId, messages[i]);
        changed = true;
      } catch (_) {
        // Keep the encrypted local outbox row for the next foreground retry.
      }
    }
    if (!changed) return;
    await history.write(
      key,
      jsonEncode({
        'conversation': archive['conversation'],
        'messages': messages.map(_archiveJson).toList(),
      }),
    );
    notifyListeners();
  }

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
    final security = await _groupSecurityState(conversationId);
    if (security['e2ee_enabled'] == true) {
      if (type != 'text' || metadata != null || mediaUrl != null) {
        throw StateError(
          'Encrypted groups currently support text and quoted replies only.',
        );
      }
      return _sendEncryptedGroupMessage(
        conversationId,
        content,
        security,
        parentMessageId: parentMessageId,
      );
    }
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
    String? conversationId;
    for (final entry in _messages.entries) {
      if (entry.value.any((message) => message.id == messageId)) {
        conversationId = entry.key;
        break;
      }
    }
    if (conversationId != null &&
        (await _groupSecurityState(conversationId))['e2ee_enabled'] == true) {
      throw StateError('Editing is not supported in encrypted groups yet.');
    }
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
          senderAvatar: messages[idx].senderAvatar,
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
          if ((record['metadata'] as Map?)?['e2ee'] == true) {
            unawaited(loadMessages(conversationId));
            return;
          }
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

  RealtimeChannel? _membershipSub;
  RealtimeChannel? _conversationActivitySub;

  /// Subscribes to conversation_members changes for the current user so the
  /// home group list unread badges stay in sync.
  void subscribeToMembership() {
    if (_membershipSub != null) return;
    final uid = client.auth.currentUser?.id;
    if (uid == null) return;
    _membershipSub =
        client
            .channel('membership:$uid')
            .onPostgresChanges(
              event: PostgresChangeEvent.all,
              schema: 'public',
              table: 'conversation_members',
              filter: PostgresChangeFilter(
                type: PostgresChangeFilterType.eq,
                column: 'user_id',
                value: uid,
              ),
              callback: (payload) {
                unawaited(loadConversations());
              },
            )
          ..subscribe();
    // A new message changes list ordering and unread counts but does not
    // mutate membership rows. Watch visible group messages as well so Home
    // updates immediately instead of requiring a manual refresh.
    _conversationActivitySub =
        client
            .channel('group-activity:$uid')
            .onPostgresChanges(
              event: PostgresChangeEvent.all,
              schema: 'public',
              table: 'group_messages',
              callback: (_) => unawaited(loadConversations()),
            )
          ..subscribe();
  }

  void unsubscribeFromMembership() {
    _membershipSub?.unsubscribe();
    _membershipSub = null;
    _conversationActivitySub?.unsubscribe();
    _conversationActivitySub = null;
  }

  @override
  void dispose() {
    _realtimeSub?.cancel();
    _membershipSub?.unsubscribe();
    _conversationActivitySub?.unsubscribe();
    super.dispose();
  }
}
