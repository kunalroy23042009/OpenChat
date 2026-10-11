import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../widgets/formatted_text.dart';
import '../widgets/message_actions.dart';
import '../widgets/status_ticks.dart';
import '../widgets/whatsapp_wallpaper.dart';
import '../calling/call_screen.dart';
import 'conversation_repository.dart';
import 'typing_presence.dart';
import 'team_tools_page.dart';

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
  });

  final String conversationId;
  final String conversationTitle;
  final String conversationType; // 'group' | 'channel'
  final String? avatarUrl;
  final int memberCount;

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  late final ConversationRepository _repo;
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();

  bool _isLoading = true;
  String? _error;

  // Realtime Presence
  TypingPresence? _typingPresence;
  String? _presenceStatus;

  // Active interaction states
  GroupMessage? _replyingTo;
  GroupMessage? _editingMessage;

  String get _currentUserId =>
      Supabase.instance.client.auth.currentUser?.id ?? '';

  @override
  void initState() {
    super.initState();
    _repo = ConversationRepository(Supabase.instance.client);
    _repo.addListener(_onRepoChanged);
    _initChat();
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

    if (myId != null) {
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
      await _repo.loadMessages(widget.conversationId);
      _repo.subscribeToConversation(widget.conversationId);
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
    _textController.dispose();
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

    _textController.clear();
    final replyId = _replyingTo?.id;
    setState(() => _replyingTo = null);

    try {
      await _repo.sendMessage(
        widget.conversationId,
        text,
        parentMessageId: replyId,
      );
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
    final session = ActiveCallSession(
      callId:
          '${widget.conversationId}-${DateTime.now().millisecondsSinceEpoch}',
      peerUsername: widget.conversationId,
      peerDisplayName: widget.conversationTitle,
      type: type,
    );
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (context) => CallScreen(
          session: session,
          onEndCall: () => Navigator.pop(context),
        ),
      ),
    );
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
        onEdit: isMine && msg.isEditable
            ? () {
                Navigator.pop(ctx);
                _startEdit(msg);
              }
            : null,
        onStar: () => _repo.toggleStar(msg.id),
        onPin: () => _repo.togglePin(widget.conversationId, msg.id),
        onDeleteForMe: () => _repo.deleteMessage(msg.id, forEveryone: false),
        onDeleteForEveryone: isMine
            ? () => _repo.deleteMessage(msg.id, forEveryone: true)
            : null,
        onConvertToTask: () => _showTaskDialog(source: msg),
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
        actions: [
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
                    _presenceStatus != null && _presenceStatus!.isNotEmpty
                        ? _presenceStatus!
                        : widget.memberCount > 0
                        ? '${widget.memberCount} members'
                        : widget.conversationType,
                    style: TextStyle(
                      fontSize: 12,
                      color:
                          _presenceStatus != null && _presenceStatus!.isNotEmpty
                          ? const Color(0xFF25D366)
                          : (isDark ? Colors.white60 : Colors.black54),
                      fontWeight:
                          _presenceStatus != null && _presenceStatus!.isNotEmpty
                          ? FontWeight.w500
                          : FontWeight.normal,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
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
                      itemCount: messages.length,
                      itemBuilder: (context, index) {
                        final msg = messages[index];
                        final isMine = msg.senderId == _currentUserId;

                        return GestureDetector(
                          onLongPress: () => _openMessageActions(msg),
                          child: _buildGroupBubble(msg, isMine, isDark),
                        );
                      },
                    ),
            ),

            // Reply / Edit Banner
            if (_replyingTo != null) _buildReplyBar(isDark),
            if (_editingMessage != null) _buildEditBar(isDark),

            // Chat input bar
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
            // Sender name (for incoming group messages)
            if (!isMine && msg.senderName != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  msg.senderName!,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF00A884),
                  ),
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
                if (isMine) ...[
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
          children: [
            _attachmentItem(
              Icons.insert_drive_file,
              'Document',
              Colors.indigo,
              () {},
            ),
            _attachmentItem(Icons.camera_alt, 'Camera', Colors.pink, () {}),
            _attachmentItem(Icons.photo, 'Gallery', Colors.purple, () {}),
            _attachmentItem(Icons.headphones, 'Audio', Colors.orange, () {}),
            _attachmentItem(Icons.location_on, 'Location', Colors.green, () {}),
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
