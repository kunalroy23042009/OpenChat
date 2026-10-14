import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../widgets/formatted_text.dart';
import '../widgets/message_actions.dart';
import '../widgets/status_ticks.dart';
import '../widgets/whatsapp_wallpaper.dart';
import '../calling/call_screen.dart';
import '../contacts_repository.dart';
import 'conversation_repository.dart';
import 'typing_presence.dart';
import 'team_tools_page.dart';
import '../security/secure_history_database.dart';

/// Full-featured Group and Channel chat screen.
///
/// Implements WhatsApp-grade UI with:
/// - Real-time message streaming via Supabase Realtime
/// - Typing indicators & presence ("Alice is typing...", "Bob is recording audio...")
/// - Pinned messages carousel / banner
/// - Quoted reply preview and thread navigation
/// - Inline message reactions
/// - 15-minute edit window & tombstone deletion ("This message was deleted")
/// - WhatsApp rich text formatting (*bold*, _italic_, ~strike~, ```code```)
class GroupChatScreen extends StatefulWidget {
  const GroupChatScreen({
    super.key,
    required this.conversationId,
    required this.conversationTitle,
    this.conversationType = 'group',
    this.avatarUrl,
    this.memberCount = 0,
    this.secureHistory,
    this.readOnlyArchive = false,
    this.e2eeEnabled = false,
  });

  final String conversationId;
  final String conversationTitle;
  final String conversationType; // 'group' | 'channel'
  final String? avatarUrl;
  final int memberCount;
  final SecureHistoryDatabase? secureHistory;
  final bool readOnlyArchive;
  final bool e2eeEnabled;

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  late final ConversationRepository _repo;
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();

  bool _isLoading = true;
  bool _loadingOlder = false;
  bool _hasMoreHistory = true;
  String? _error;

  // Realtime Presence
  TypingPresence? _typingPresence;
  String? _presenceStatus;

  // Active interaction states
  GroupMessage? _replyingTo;
  GroupMessage? _editingMessage;

  /// Sender profile photos by user id, resolved through contacts.
  /// Server rows carry no avatar (profiles are self-read-only), so the
  /// contacts listing is the accessible source of truth.
  final Map<String, String> _senderAvatars = {};

  String? _senderAvatarFor(GroupMessage msg) {
    final server = msg.senderAvatar;
    if (server != null && server.isNotEmpty) return server;
    final known = _senderAvatars[msg.senderId];
    return (known != null && known.isNotEmpty) ? known : null;
  }

  Future<void> _loadSenderAvatars() async {
    try {
      final contacts = await SupabaseContactsRepository(
        Supabase.instance.client,
      ).contacts();
      if (!mounted) return;
      setState(() {
        for (final c in contacts) {
          if (c.avatarUrl != null && c.avatarUrl!.isNotEmpty) {
            _senderAvatars[c.userId] = c.avatarUrl!;
          }
        }
      });
    } catch (_) {}
  }

  String get _currentUserId =>
      Supabase.instance.client.auth.currentUser?.id ?? '';

  @override
  void initState() {
    super.initState();
    _repo = ConversationRepository(
      Supabase.instance.client,
      secureHistory: widget.secureHistory,
      archiveConversation: {
        'id': widget.conversationId,
        'type': widget.conversationType,
        'title': widget.conversationTitle,
        'avatar_url': widget.avatarUrl,
        'e2ee_enabled': widget.e2eeEnabled,
      },
    );
    _repo.addListener(_onRepoChanged);
    _scrollController.addListener(_onHistoryScroll);
    _initChat();
  }

  void _onHistoryScroll() {
    if (!_scrollController.hasClients ||
        _loadingOlder ||
        !_hasMoreHistory ||
        _isLoading) {
      return;
    }
    // This list is reversed: its largest scroll offset is the oldest end.
    if (_scrollController.position.maxScrollExtent -
            _scrollController.position.pixels <=
        240) {
      unawaited(_loadOlderMessages());
    }
  }

  Future<void> _loadOlderMessages() async {
    if (_loadingOlder || !_hasMoreHistory) return;
    final loaded = _repo.messagesFor(widget.conversationId);
    if (loaded.isEmpty) {
      _hasMoreHistory = false;
      return;
    }
    setState(() => _loadingOlder = true);
    try {
      final count = await _repo.loadMessages(
        widget.conversationId,
        before: loaded.last.createdAt,
      );
      if (mounted && count < ConversationRepository.messagePageSize) {
        setState(() => _hasMoreHistory = false);
      }
    } catch (_) {
      // Keep the paging affordance active so scrolling up retries.
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  void _onRepoChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _initChat() async {
    final client = Supabase.instance.client;
    final myId = client.auth.currentUser?.id;
    final myName =
        client.auth.currentUser?.userMetadata?['name'] as String? ??
        client.auth.currentUser?.phone ??
        'User';

    if (myId != null && !widget.readOnlyArchive) {
      _typingPresence = TypingPresence(
        client: client,
        conversationId: widget.conversationId,
        userId: myId,
        displayName: myName,
        onPresenceChange: (states) {
          if (mounted) {
            setState(() {
              _presenceStatus = _typingPresence?.statusText;
            });
          }
        },
      );
      _typingPresence?.join();
    }

    try {
      unawaited(_loadSenderAvatars());
      if (!widget.readOnlyArchive) {
        unawaited(_repo.updatePresence(isOnline: true));
      }
      final count = await _repo.loadMessages(widget.conversationId);
      _hasMoreHistory = count == ConversationRepository.messagePageSize;
      if (widget.e2eeEnabled && !widget.readOnlyArchive) {
        await _repo.retryPendingGroupMessages(widget.conversationId);
      }
      if (!widget.readOnlyArchive) {
        _repo.subscribeToConversation(widget.conversationId);
      } else {
        _hasMoreHistory = false;
      }
      if (mounted) setState(() => _isLoading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }

    _textController.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    if (_textController.text.isNotEmpty) {
      _typingPresence?.onKeystroke();
    }
  }

  @override
  void dispose() {
    if (!widget.readOnlyArchive) {
      unawaited(_repo.updatePresence(isOnline: false));
    }
    _textController.dispose();
    _scrollController.removeListener(_onHistoryScroll);
    _scrollController.dispose();
    _focusNode.dispose();
    _typingPresence?.dispose();
    _repo.removeListener(_onRepoChanged);
    _repo.unsubscribeFromConversation();
    _repo.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _sendMessage() async {
    if (widget.readOnlyArchive) return;
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    if (_editingMessage != null) {
      final target = _editingMessage!;
      _cancelEdit();
      try {
        await _repo.editMessage(target.id, text);
      } catch (e) {
        _showToast('Failed to edit: $e');
      }
      return;
    }

    final replyId = _replyingTo?.id;
    final pending = _repo
        .messagesFor(widget.conversationId)
        .where(
          (message) =>
              message.isPending &&
              message.content == text &&
              message.parentMessageId == replyId,
        );
    try {
      if (pending.isNotEmpty) {
        final pendingId = pending.first.id;
        await _repo.retryPendingGroupMessages(widget.conversationId);
        final stillPending = _repo
            .messagesFor(widget.conversationId)
            .any((message) => message.id == pendingId && message.isPending);
        if (stillPending) {
          _showToast('Message is still pending; it will retry when connected.');
          return;
        }
      } else {
        await _repo.sendMessage(
          widget.conversationId,
          text,
          parentMessageId: replyId,
        );
      }
      _textController.clear();
      if (mounted) setState(() => _replyingTo = null);
      _scrollToBottom();
    } catch (e) {
      _showToast('Failed to send: $e');
    }
  }

  void _startReply(GroupMessage msg) {
    setState(() {
      _replyingTo = msg;
      _editingMessage = null;
    });
    _focusNode.requestFocus();
  }

  void _startEdit(GroupMessage msg) {
    setState(() {
      _editingMessage = msg;
      _replyingTo = null;
      _textController.text = msg.content;
    });
    _focusNode.requestFocus();
  }

  void _cancelEdit() {
    setState(() {
      _editingMessage = null;
      _textController.clear();
    });
  }

  void _showToast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  void _startGroupCall(CallType type) {
    // No group-call media path exists (1:1 LiveKit calls only). Opening the
    // call screen here would land on a dead-end placeholder, so fail loudly.
    _showToast('Group calls aren\'t available yet. Use 1:1 encrypted chats.');
  }

  void _openMessageActions(GroupMessage msg) {
    final isMine = msg.senderId == _currentUserId;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => MessageActionsSheet(
        messageText: msg.content,
        isMine: isMine,
        isEditable: msg.isEditable,
        isPinned: msg.isPinned,
        isStarred: msg.isStarred,
        onReact: (emoji) => _repo.reactToMessage(msg.id, emoji),
        onMoreReactions: () => _showReactionPicker(msg),
        onReply: () {
          Navigator.pop(ctx);
          _startReply(msg);
        },
        onEdit: !widget.e2eeEnabled && isMine && msg.isEditable
            ? () {
                Navigator.pop(ctx);
                _startEdit(msg);
              }
            : null,
        onStar: () => _repo.toggleStar(msg.id),
        onPin: () => _repo.togglePin(widget.conversationId, msg.id),
        onDeleteForMe: widget.e2eeEnabled
            ? null
            : () => _repo.deleteMessage(msg.id, forEveryone: false),
        onDeleteForEveryone: isMine
            ? () => _repo.deleteMessage(msg.id, forEveryone: true)
            : null,
        onInfo: isMine
            ? () {
                Navigator.pop(ctx);
                showModalBottomSheet<void>(
                  context: context,
                  builder: (_) => MessageInfoSheet(
                    messageText: msg.content,
                    sentAt: msg.createdAt,
                    editedAt: msg.editedAt,
                    isEdited: msg.isEdited,
                  ),
                );
              }
            : null,
        onConvertToTask: widget.e2eeEnabled
            ? null
            : () => _showTaskDialog(source: msg),
      ),
    );
  }

  Future<void> _showReactionPicker(GroupMessage message) async {
    const reactions = [
      '😀',
      '😁',
      '😍',
      '🥳',
      '🤔',
      '👏',
      '🔥',
      '✅',
      '💯',
      '🚀',
    ];
    final emoji = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Choose a reaction'),
        content: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: reactions
              .map(
                (value) => InkWell(
                  onTap: () => Navigator.pop(context, value),
                  child: Text(value, style: const TextStyle(fontSize: 30)),
                ),
              )
              .toList(),
        ),
      ),
    );
    if (emoji != null) await _repo.reactToMessage(message.id, emoji);
  }

  Future<void> _showTaskDialog({GroupMessage? source}) async {
    final title = TextEditingController(text: source?.content ?? '');
    String priority = 'medium';
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            source == null ? 'Create task' : 'Convert message to task',
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: title,
                maxLength: 150,
                decoration: const InputDecoration(labelText: 'Task title'),
              ),
              DropdownButtonFormField<String>(
                initialValue: priority,
                decoration: const InputDecoration(labelText: 'Priority'),
                items: const ['low', 'medium', 'high', 'urgent']
                    .map(
                      (value) => DropdownMenuItem(
                        value: value,
                        child: Text(value.toUpperCase()),
                      ),
                    )
                    .toList(),
                onChanged: (value) =>
                    setDialogState(() => priority = value ?? 'medium'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
    if (accepted == true && title.text.trim().isNotEmpty) {
      await _repo.createTask(
        widget.conversationId,
        title.text.trim(),
        priority: priority,
        messageId: source?.id,
      );
      if (mounted) _showToast('Task created');
    }
    title.dispose();
  }

  Future<void> _showPollDialog() async {
    final question = TextEditingController();
    final options = List.generate(4, (_) => TextEditingController());
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create poll'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: question,
                decoration: const InputDecoration(labelText: 'Question'),
              ),
              ...options.asMap().entries.map(
                (entry) => TextField(
                  controller: entry.value,
                  decoration: InputDecoration(
                    labelText: 'Option ${entry.key + 1}',
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: widget.readOnlyArchive
            ? const []
            : [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Send'),
                ),
              ],
      ),
    );
    final values = options
        .map((controller) => controller.text.trim())
        .where((value) => value.isNotEmpty)
        .toList();
    if (accepted == true &&
        question.text.trim().isNotEmpty &&
        values.length >= 2) {
      await _repo.createPoll(
        widget.conversationId,
        question.text.trim(),
        values,
      );
    } else if (accepted == true && mounted) {
      _showToast('Add a question and at least two options');
    }
    question.dispose();
    for (final option in options) {
      option.dispose();
    }
  }

  /// Member roster with role badges. Admins/owners can remove members;
  /// anyone can leave. Backed by list_conversation_members.
  Future<void> _showMembers() async {
    List<Map<String, dynamic>> roster = [];
    String? error;
    try {
      roster = await _repo.members(widget.conversationId);
    } catch (_) {
      error = 'Could not load members. Check your connection.';
    }
    if (!mounted) return;
    final myId = _currentUserId;
    var myRole = 'member';
    for (final m in roster) {
      if (m['user_id'] == myId) myRole = (m['role'] as String?) ?? 'member';
    }
    final canManage = myRole == 'admin' || myRole == 'owner';
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '${widget.conversationTitle} • ${roster.length} members',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (error != null)
              Padding(padding: const EdgeInsets.all(16), child: Text(error))
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: roster.length,
                  itemBuilder: (ctx, i) {
                    final m = roster[i];
                    final id = (m['user_id'] ?? '').toString();
                    final name =
                        (m['display_name'] as String?)?.isNotEmpty == true
                        ? m['display_name'] as String
                        : 'Member ${id.length >= 8 ? id.substring(0, 8) : id}';
                    final role = (m['role'] as String?) ?? 'member';
                    final isMe = id == myId;
                    final kickable = canManage && !isMe && role != 'owner';
                    return ListTile(
                      leading: CircleAvatar(
                        foregroundImage: (_senderAvatars[id] ?? '').isNotEmpty
                            ? NetworkImage(_senderAvatars[id]!)
                            : null,
                        child: Text(name.isEmpty ? '?' : name[0].toUpperCase()),
                      ),
                      title: Text(name),
                      subtitle: Text(
                        '@${(m['username'] as String?) ?? 'unknown'}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (role != 'member')
                            Chip(
                              label: Text(role),
                              visualDensity: VisualDensity.compact,
                            ),
                          if (kickable)
                            IconButton(
                              tooltip: 'Remove member',
                              icon: const Icon(Icons.person_remove_outlined),
                              onPressed: () async {
                                final confirmed = await showDialog<bool>(
                                  context: ctx,
                                  builder: (dctx) => AlertDialog(
                                    title: Text('Remove $name?'),
                                    content: const Text(
                                      'They will stop receiving new messages.',
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(dctx, false),
                                        child: const Text('Cancel'),
                                      ),
                                      FilledButton(
                                        onPressed: () =>
                                            Navigator.pop(dctx, true),
                                        child: const Text('Remove'),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirmed != true) return;
                                try {
                                  await _repo.removeMember(
                                    widget.conversationId,
                                    id,
                                  );
                                  if (!mounted) return;
                                  Navigator.pop(context);
                                  _showToast('$name removed.');
                                } catch (_) {
                                  if (ctx.mounted) {
                                    ScaffoldMessenger.of(ctx).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          'Could not remove member.',
                                        ),
                                      ),
                                    );
                                  }
                                }
                              },
                            ),
                          if (isMe)
                            TextButton(
                              onPressed: () async {
                                try {
                                  await _repo.removeMember(
                                    widget.conversationId,
                                    myId,
                                  );
                                  if (!mounted) return;
                                  Navigator.pop(context);
                                  Navigator.pop(context);
                                } catch (_) {
                                  if (ctx.mounted) {
                                    ScaffoldMessenger.of(ctx).showSnackBar(
                                      const SnackBar(
                                        content: Text('Could not leave.'),
                                      ),
                                    );
                                  }
                                }
                              },
                              child: const Text('Leave'),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final messages = _repo.messagesFor(widget.conversationId);
    final pinnedMessages = messages.where((m) => m.isPinned).toList();

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: const Color(0xFF00A884).withValues(alpha: 0.2),
              backgroundImage: widget.avatarUrl != null
                  ? NetworkImage(widget.avatarUrl!)
                  : null,
              child: widget.avatarUrl == null
                  ? Icon(
                      widget.conversationType == 'channel'
                          ? Icons.campaign
                          : Icons.group,
                      color: const Color(0xFF00A884),
                      size: 20,
                    )
                  : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: InkWell(
                onTap: widget.readOnlyArchive ? null : _showMembers,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.conversationTitle,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      widget.readOnlyArchive
                          ? 'Recovered archive · read only'
                          : _presenceStatus != null &&
                                _presenceStatus!.isNotEmpty
                          ? _presenceStatus!
                          : widget.memberCount > 0
                          ? '${widget.memberCount} members'
                          : widget.conversationType,
                      style: TextStyle(
                        fontSize: 12,
                        color:
                            _presenceStatus != null &&
                                _presenceStatus!.isNotEmpty
                            ? const Color(0xFF25D366)
                            : (isDark ? Colors.white60 : Colors.black54),
                        fontWeight:
                            _presenceStatus != null &&
                                _presenceStatus!.isNotEmpty
                            ? FontWeight.w500
                            : FontWeight.normal,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.videocam_outlined),
            tooltip: 'Group Video Call',
            onPressed: () => _startGroupCall(CallType.video),
          ),
          IconButton(
            icon: const Icon(Icons.call_outlined),
            tooltip: 'Group Audio Call',
            onPressed: () => _startGroupCall(CallType.voice),
          ),
          PopupMenuButton<String>(
            onSelected: (val) {
              if (val == 'info') {
                _showToast('Group info');
              } else if (val == 'clear') {
                _showToast('Clear chat');
              } else if (val == 'tasks') {
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => TaskBoardPage(
                      repository: _repo,
                      conversationId: widget.conversationId,
                    ),
                  ),
                );
              } else if (val == 'vault') {
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => ResourceVaultPage(
                      messages: _repo.messagesFor(widget.conversationId),
                    ),
                  ),
                );
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(value: 'info', child: Text('Group info')),
              const PopupMenuItem(
                value: 'media',
                child: Text('Group media & docs'),
              ),
              const PopupMenuItem(value: 'tasks', child: Text('Task board')),
              const PopupMenuItem(
                value: 'vault',
                child: Text('Resource vault'),
              ),
              const PopupMenuItem(value: 'search', child: Text('Search')),
              const PopupMenuItem(
                value: 'mute',
                child: Text('Mute notifications'),
              ),
              const PopupMenuItem(value: 'clear', child: Text('Clear chat')),
            ],
          ),
        ],
      ),
      body: WhatsAppWallpaper(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              color: Colors.amber.withValues(alpha: 0.14),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 16, color: Colors.amber),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.e2eeEnabled
                          ? 'End-to-end encrypted group text is enabled. Media, polls and tasks are disabled in encrypted groups.'
                          : 'This is a legacy group. Its messages are not end-to-end encrypted; create a new group for confidential messages.',
                      style: TextStyle(fontSize: 12, height: 1.3),
                    ),
                  ),
                ],
              ),
            ),
            // Pinned message banner (if any)
            if (pinnedMessages.isNotEmpty)
              _buildPinnedBanner(pinnedMessages.first, isDark),

            // Message stream
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(child: Text('Error: $_error'))
                  : messages.isEmpty
                  ? _buildEmptyState(isDark)
                  : ListView.builder(
                      controller: _scrollController,
                      reverse: true,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      itemCount: messages.length + (_loadingOlder ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index >= messages.length) {
                          return const Padding(
                            padding: EdgeInsets.all(16),
                            child: Center(
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                          );
                        }
                        final msg = messages[index];
                        final isMine = msg.senderId == _currentUserId;

                        return GestureDetector(
                          onLongPress: widget.readOnlyArchive
                              ? null
                              : () => _openMessageActions(msg),
                          child: _buildGroupBubble(msg, isMine, isDark),
                        );
                      },
                    ),
            ),

            // Reply / Edit Banner
            if (_replyingTo != null) _buildReplyBar(isDark),
            if (_editingMessage != null) _buildEditBar(isDark),

            // Chat input bar
            if (widget.readOnlyArchive)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                color: isDark ? const Color(0xFF202C33) : Colors.white,
                child: const Text(
                  'This restored group history is read-only.',
                  textAlign: TextAlign.center,
                ),
              )
            else
              _buildInputBar(isDark),
          ],
        ),
      ),
    );
  }

  Widget _buildPinnedBanner(GroupMessage msg, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1F2C34) : Colors.white,
        border: Border(
          bottom: BorderSide(
            color: isDark ? Colors.white12 : Colors.black12,
            width: 0.8,
          ),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.push_pin, size: 16, color: Color(0xFF00A884)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Pinned Message',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF00A884),
                  ),
                ),
                Text(
                  msg.content,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white70 : Colors.black87,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            onPressed: () => _repo.togglePin(widget.conversationId, msg.id),
          ),
        ],
      ),
    );
  }

  Widget _buildReplyBar(bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1F2C34) : const Color(0xFFF0F2F5),
        border: const Border(
          left: BorderSide(color: Color(0xFF00A884), width: 4),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _replyingTo!.senderName ?? 'User',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF00A884),
                  ),
                ),
                Text(
                  _replyingTo!.content,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white70 : Colors.black87,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() => _replyingTo = null),
          ),
        ],
      ),
    );
  }

  Widget _buildEditBar(bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: isDark ? const Color(0xFF1F2C34) : const Color(0xFFFFF9C4),
      child: Row(
        children: [
          const Icon(Icons.edit, size: 16, color: Colors.orange),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Editing message...',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: _cancelEdit,
          ),
        ],
      ),
    );
  }

  Widget _buildGroupBubble(GroupMessage msg, bool isMine, bool isDark) {
    // Deleted message tombstone
    if (msg.isDeleted) {
      return Align(
        alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1F2C34) : Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.block, size: 14, color: Colors.grey[600]),
              const SizedBox(width: 6),
              Text(
                'This message was deleted',
                style: TextStyle(
                  fontStyle: FontStyle.italic,
                  fontSize: 13,
                  color: Colors.grey[600],
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (msg.type == 'poll') {
      final meta = msg.metadata;
      final options =
          (meta?['options'] as List?)?.whereType<String>().toList() ?? const [];
      if (options.length >= 2) {
        return Align(
          alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
          child: _GroupPollCard(
            conversationId: widget.conversationId,
            msg: msg,
            options: options,
            multiple: meta?['multiple'] == true,
            isMine: isMine,
            repo: _repo,
          ),
        );
      }
    }

    final bubbleColor = isMine
        ? (isDark ? const Color(0xFF005C4B) : const Color(0xFFD9FDD3))
        : (isDark ? const Color(0xFF1F2C34) : Colors.white);

    final textColor = isDark ? Colors.white : const Color(0xFF111B21);

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 3,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Sender profile + name (for incoming group messages)
            if (!isMine && msg.senderName != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(
                      radius: 10,
                      backgroundColor: const Color(0xFFE4EBFF),
                      foregroundImage: (_senderAvatarFor(msg) ?? '').isNotEmpty
                          ? NetworkImage(_senderAvatarFor(msg)!)
                          : null,
                      child: Text(
                        msg.senderName!.isEmpty
                            ? '?'
                            : msg.senderName![0].toUpperCase(),
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF245CDB),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        msg.senderName!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF00A884),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            // Rich formatted text message
            FormattedText(
              text: msg.content,
              baseStyle: TextStyle(
                fontSize: 14.5,
                color: textColor,
                height: 1.3,
              ),
            ),

            const SizedBox(height: 3),

            // Metadata row: edited badge, star, pin, time, ticks
            Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (msg.isPinned)
                  const Padding(
                    padding: EdgeInsets.only(right: 4),
                    child: Icon(Icons.push_pin, size: 12, color: Colors.grey),
                  ),
                if (msg.isStarred)
                  const Padding(
                    padding: EdgeInsets.only(right: 4),
                    child: Icon(Icons.star, size: 12, color: Colors.amber),
                  ),
                if (msg.isEdited)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Text(
                      'Edited',
                      style: TextStyle(fontSize: 10, color: Colors.grey[500]),
                    ),
                  ),
                Text(
                  '${msg.createdAt.hour.toString().padLeft(2, '0')}:${msg.createdAt.minute.toString().padLeft(2, '0')}',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: isDark ? Colors.white54 : Colors.black45,
                  ),
                ),
                if (isMine && msg.isPending)
                  Padding(
                    padding: const EdgeInsets.only(left: 5),
                    child: Text(
                      'Pending',
                      style: TextStyle(fontSize: 10, color: Colors.orange[700]),
                    ),
                  )
                else if (isMine) ...[
                  const SizedBox(width: 4),
                  const MessageStatusTicks(
                    state: MessageDeliveryState.delivered,
                    size: 14,
                  ),
                ],
              ],
            ),

            // Reactions pill row
            if (msg.reactionsGrouped.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Wrap(
                  spacing: 4,
                  children: msg.reactionsGrouped.entries.map((e) {
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: isDark
                            ? const Color(0xFF121B22)
                            : const Color(0xFFF0F2F5),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.grey.withValues(alpha: 0.2),
                          width: 0.5,
                        ),
                      ),
                      child: Text(
                        '${e.key} ${e.value.length}',
                        style: const TextStyle(fontSize: 11),
                      ),
                    );
                  }).toList(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(bool isDark) {
    return Center(
      child: Container(
        margin: const EdgeInsets.all(24),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: (isDark ? const Color(0xFF1F2C34) : Colors.white).withValues(
            alpha: 0.85,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              widget.conversationType == 'channel'
                  ? Icons.campaign
                  : Icons.groups_2,
              size: 40,
              color: const Color(0xFF00A884),
            ),
            const SizedBox(height: 8),
            Text(
              'Welcome to ${widget.conversationTitle}!',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
            const SizedBox(height: 4),
            Text(
              widget.conversationType == 'channel'
                  ? 'This is a broadcast channel. Send updates to your subscribers.'
                  : 'Start conversations, collaborate with your team, and share media.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.white60 : Colors.black54,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputBar(bool isDark) {
    final bg = isDark ? const Color(0xFF1F2C34) : Colors.white;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      color: Colors.transparent,
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.emoji_emotions_outlined),
                      color: Colors.grey[600],
                      onPressed: () => _showToast('Emoji picker'),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _textController,
                        focusNode: _focusNode,
                        maxLines: 5,
                        minLines: 1,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: const InputDecoration(
                          hintText: 'Message',
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(vertical: 8),
                        ),
                      ),
                    ),
                    if (!widget.e2eeEnabled) ...[
                      IconButton(
                        icon: const Icon(Icons.attach_file),
                        color: Colors.grey[600],
                        onPressed: () => _showAttachmentSheet(),
                      ),
                      IconButton(
                        icon: const Icon(Icons.camera_alt_outlined),
                        color: Colors.grey[600],
                        onPressed: () => _showToast('Camera'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(width: 6),
            CircleAvatar(
              radius: 22,
              backgroundColor: const Color(0xFF00A884),
              child: IconButton(
                icon: Icon(
                  _editingMessage != null
                      ? Icons.check
                      : _textController.text.isNotEmpty
                      ? Icons.send
                      : Icons.mic,
                  color: Colors.white,
                  size: 20,
                ),
                onPressed: _sendMessage,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showAttachmentSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF1F2C34)
              : Colors.white,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Wrap(
          spacing: 20,
          runSpacing: 20,
          alignment: WrapAlignment.spaceAround,
          // Only actions with a real implementation are shown. Media
          // uploads were never wired for groups; dead tiles were removed
          // rather than silently closing the sheet.
          children: [
            _attachmentItem(
              Icons.poll,
              'Poll',
              const Color(0xFF00A884),
              _showPollDialog,
            ),
            _attachmentItem(Icons.task, 'Task', Colors.blue, _showTaskDialog),
          ],
        ),
      ),
    );
  }

  Widget _attachmentItem(
    IconData icon,
    String label,
    Color color,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: () {
        Navigator.pop(context);
        onTap();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 26,
            backgroundColor: color,
            child: Icon(icon, color: Colors.white, size: 24),
          ),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}

/// Group poll card with live tallies. Tapping an option casts a ballot
/// via vote_poll (single-choice replaces, multi-choice accumulates).
class _GroupPollCard extends StatefulWidget {
  const _GroupPollCard({
    required this.conversationId,
    required this.msg,
    required this.options,
    required this.multiple,
    required this.isMine,
    required this.repo,
  });
  final String conversationId;
  final GroupMessage msg;
  final List<String> options;
  final bool multiple;
  final bool isMine;
  final ConversationRepository repo;

  @override
  State<_GroupPollCard> createState() => _GroupPollCardState();
}

class _GroupPollCardState extends State<_GroupPollCard> {
  List<Map<String, dynamic>> _votes = [];
  bool _loading = true;
  bool _voting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final votes = await widget.repo.pollVotes(widget.msg.id);
      if (mounted) setState(() => _votes = votes);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _vote(int index) async {
    if (_voting) return;
    setState(() => _voting = true);
    try {
      await widget.repo.votePoll(widget.conversationId, widget.msg.id, index);
      await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Vote failed. Try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _voting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final counts = List<int>.filled(widget.options.length, 0);
    for (final v in _votes) {
      final i = (v['option_index'] as num?)?.toInt();
      if (i != null && i >= 0 && i < counts.length) counts[i]++;
    }
    final total = counts.fold(0, (a, b) => a + b);
    return Align(
      alignment: widget.isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: widget.isMine
              ? (isDark ? const Color(0xFF005C4B) : const Color(0xFFD9FDD3))
              : (isDark ? const Color(0xFF1F2C34) : Colors.white),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!widget.isMine && widget.msg.senderName != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  widget.msg.senderName!,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF00A884),
                  ),
                ),
              ),
            Text(
              widget.msg.content,
              style: const TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            if (_loading)
              const LinearProgressIndicator()
            else
              for (var i = 0; i < widget.options.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: InkWell(
                    onTap: _voting ? null : () => _vote(i),
                    borderRadius: BorderRadius.circular(8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(child: Text(widget.options[i])),
                            Text(
                              '${counts[i]}',
                              style: TextStyle(
                                fontSize: 12,
                                color: isDark ? Colors.white60 : Colors.black54,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        LinearProgressIndicator(
                          value: total == 0 ? 0 : counts[i] / total,
                        ),
                      ],
                    ),
                  ),
                ),
            Text(
              '$total vote${total == 1 ? '' : 's'}${widget.multiple ? ' • multiple choice' : ''}',
              style: TextStyle(
                fontSize: 11,
                color: isDark ? Colors.white60 : Colors.black54,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
