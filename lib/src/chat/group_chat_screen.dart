import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../widgets/formatted_text.dart';
import '../widgets/message_actions.dart';
import '../widgets/status_ticks.dart';
import '../widgets/whatsapp_wallpaper.dart';
import '../calling/group_voice_chat.dart';
import '../chat_preferences.dart';
import '../contacts_repository.dart';
import '../push/notify_service.dart';
import 'chat_routes.dart';
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

class _GroupChatScreenState extends State<GroupChatScreen>
    with WidgetsBindingObserver, RouteAware {
  late final ConversationRepository _repo;
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();

  bool _isLoading = true;
  bool _markingRead = false;
  DateTime? _lastRead;
  bool _loadingOlder = false;
  bool _hasMoreHistory = true;
  String? _error;
  SharedPreferences? _preferences;
  ChatWallpaperPreset _wallpaperPreset = ChatWallpaperPreset.classic;

  /// Local "clear chat" cursor: messages at or before this time are hidden
  /// on this device only (WhatsApp-style clear), without deleting for others.
  DateTime? _clearedAt;

  /// Live group settings, editable by admins (falls back to widget values).
  String? _groupTitle;
  String? _groupDescription;
  String? _groupAvatar;
  late int _memberCount = widget.memberCount;

  String get _title => _groupTitle ?? widget.conversationTitle;
  String? get _description => _groupDescription;

  // Realtime Presence
  TypingPresence? _typingPresence;
  String? _presenceStatus;

  // Active interaction states
  GroupMessage? _replyingTo;
  GroupMessage? _editingMessage;

  /// @mentions state
  bool _showMentions = false;
  String _mentionQuery = '';
  List<Map<String, dynamic>> _mentionSuggestions = [];
  OverlayEntry? _mentionOverlay;
  final LayerLink _mentionLayerLink = LayerLink();

  /// Sender profile photos by user id, resolved from group member roster
  /// (server now returns avatar_url) and contacts as fallback.
  final Map<String, String> _senderAvatars = {};

  /// Group voice chat (drop-in audio rooms) shared app-wide; this screen
  /// only renders its state and forwards join/leave taps.
  final GroupVoiceChatService _voiceChat = GroupVoiceChatService.instance;

  /// Dismissing the banner hides it for this screen session only; it comes
  /// back on reopen or when the room updates.
  String? _dismissedVoiceRoom;

  String? _senderAvatarFor(GroupMessage msg) {
    final server = msg.senderAvatar;
    if (server != null && server.isNotEmpty) return server;
    final known = _senderAvatars[msg.senderId];
    return (known != null && known.isNotEmpty) ? known : null;
  }

  Future<void> _loadSenderAvatars() async {
    try {
      // Load from group member roster (includes avatar_url from server)
      final members = await _repo.members(widget.conversationId);
      if (!mounted) return;
      setState(() {
        _memberCount = members.length;
        for (final m in members) {
          final avatar = m['avatar_url'] as String?;
          if (avatar != null && avatar.isNotEmpty) {
            _senderAvatars[m['member_id'] as String? ??
                    m['user_id'] as String] =
                avatar;
          }
        }
      });
    } catch (_) {
      // Fallback to contacts if roster fails
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
  }

  String get _currentUserId =>
      Supabase.instance.client.auth.currentUser?.id ?? '';

  Future<void> _syncGroupMeta() async {
    try {
      await _repo.loadConversations();
      if (!mounted) return;
      for (final c in _repo.conversations) {
        if (c.id == widget.conversationId) {
          setState(() {
            _groupTitle = c.title;
            _groupDescription = c.description;
            _groupAvatar = c.avatarUrl;
          });
          break;
        }
      }
    } catch (_) {}
  }

  Future<void> _editGroupInfo() async {
    final nameController = TextEditingController(text: _title);
    final descController = TextEditingController(text: _description ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit group info'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              maxLength: 100,
              decoration: const InputDecoration(labelText: 'Group name'),
            ),
            TextField(
              controller: descController,
              maxLines: 3,
              maxLength: 500,
              decoration: const InputDecoration(labelText: 'Description'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved != true || !mounted) return;
    final newTitle = nameController.text.trim();
    if (newTitle.isEmpty) {
      _showToast('Group name cannot be empty.');
      return;
    }
    try {
      await _repo.updateConversation(
        widget.conversationId,
        title: newTitle,
        description: descController.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _groupTitle = newTitle;
        _groupDescription = descController.text.trim();
      });
      _showToast('Group info updated.');
    } catch (_) {
      if (mounted) _showToast('Could not update group info.');
    }
  }

  /// Start or join the drop-in voice room for this group. Starting is
  /// joining: the first member's RPC call creates the presence row every
  /// other member sees as a banner.
  Future<void> _startVoiceChat() => _joinVoiceChat();

  Future<void> _joinVoiceChat() async {
    if (widget.readOnlyArchive) return;
    await GroupVoiceChatService.instance.join(
      context: context,
      client: Supabase.instance.client,
      conversationId: widget.conversationId,
      conversationTitle: _title,
    );
    if (mounted && _dismissedVoiceRoom == widget.conversationId) {
      setState(() => _dismissedVoiceRoom = null);
    }
  }

  Future<void> _leaveVoiceChat() async {
    await GroupVoiceChatService.instance.leave();
    if (mounted) setState(() {});
  }

  Future<void> _pickGroupPhoto() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 86,
      maxWidth: 1440,
    );
    if (picked == null || !mounted) return;
    final userId = _currentUserId;
    if (userId.isEmpty) return;
    try {
      final path =
          '$userId/group_${widget.conversationId}_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await Supabase.instance.client.storage
          .from('avatars')
          .uploadBinary(
            path,
            await picked.readAsBytes(),
            fileOptions: const FileOptions(
              contentType: 'image/jpeg',
              upsert: true,
            ),
          );
      final url = Supabase.instance.client.storage
          .from('avatars')
          .getPublicUrl(path);
      await _repo.updateConversation(widget.conversationId, avatarUrl: url);
      if (!mounted) return;
      setState(() => _groupAvatar = url);
      _showToast('Group photo updated.');
    } catch (_) {
      if (mounted) {
        _showToast('Could not update group photo. Try another image.');
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setVisible(true);
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
    _textController.addListener(_onTextChanged);
    _initChat();
  }

  void _setVisible(bool visible) {
    final notifications = NotifyService.instance;
    if (visible && !widget.readOnlyArchive) {
      notifications.openGroups.add(widget.conversationId);
      unawaited(notifications.cancelGroup(widget.conversationId));
    } else {
      notifications.openGroups.remove(widget.conversationId);
    }
    _typingPresence?.setActive(visible);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) chatRouteObserver.subscribe(this, route);
  }

  @override
  void didPushNext() => _setVisible(false);

  @override
  void didPopNext() {
    _setVisible(true);
    unawaited(_markVisibleRead());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final visible =
        state == AppLifecycleState.resumed &&
        ModalRoute.of(context)?.isCurrent == true;
    _setVisible(visible);
    if (visible) unawaited(_markVisibleRead());
  }

  Future<void> _markVisibleRead() async {
    if (!mounted ||
        widget.readOnlyArchive ||
        _isLoading ||
        _markingRead ||
        ModalRoute.of(context)?.isCurrent != true ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed ||
        !_scrollController.hasClients ||
        _scrollController.offset > 80) {
      return;
    }
    final messages = _repo
        .messagesFor(widget.conversationId)
        .where((message) => !message.isPending)
        .toList();
    if (messages.isEmpty) return;
    final newest = messages.first.createdAt;
    if (_lastRead != null && !newest.isAfter(_lastRead!)) return;
    _markingRead = true;
    try {
      await _repo.markGroupRead(widget.conversationId, newest);
      _lastRead = newest;
      if (mounted) {
        unawaited(NotifyService.instance.cancelGroup(widget.conversationId));
      }
    } catch (_) {
      // Retry after the next incoming message, scroll, or resume.
    } finally {
      _markingRead = false;
    }
  }

  void _onTextChanged() {
    final text = _textController.text;
    if (text.isNotEmpty) {
      _typingPresence?.onKeystroke();
    } else {
      _typingPresence?.stopTyping();
    }
    final cursorPos = _textController.selection.baseOffset;
    // Check if we're typing @mention
    if (cursorPos > 0 && text.length >= cursorPos) {
      final beforeCursor = text.substring(0, cursorPos);
      final lastAtIndex = beforeCursor.lastIndexOf('@');
      if (lastAtIndex >= 0 &&
          (lastAtIndex == 0 ||
              beforeCursor[lastAtIndex - 1] == ' ' ||
              beforeCursor[lastAtIndex - 1] == '\n')) {
        final query = beforeCursor.substring(lastAtIndex + 1);
        if (query.isNotEmpty && !query.contains(' ') && !query.contains('\n')) {
          _showMentionSuggestions(query);
          return;
        }
      }
    }
    _hideMentionOverlay();
  }

  void _showMentionSuggestions(String query) async {
    _mentionQuery = query.toLowerCase();
    final members = await _repo.members(widget.conversationId);
    if (!mounted) return;
    final suggestions = members
        .where(
          (m) =>
              m['user_id'] != _currentUserId &&
              ((m['display_name'] as String? ?? '').toLowerCase().contains(
                    _mentionQuery,
                  ) ||
                  (m['username'] as String? ?? '').toLowerCase().contains(
                    _mentionQuery,
                  )),
        )
        .toList();
    setState(() {
      _mentionSuggestions = suggestions;
      _showMentions = suggestions.isNotEmpty;
    });
    if (_showMentions) {
      _showMentionOverlay();
    } else {
      _hideMentionOverlay();
    }
  }

  void _showMentionOverlay() {
    _hideMentionOverlay();
    _mentionOverlay = OverlayEntry(
      builder: (context) => CompositedTransformFollower(
        link: _mentionLayerLink,
        showWhenUnlinked: false,
        offset: const Offset(0, -200),
        child: Material(
          color: Colors.transparent,
          child: Container(
            constraints: const BoxConstraints(maxHeight: 200, maxWidth: 300),
            margin: const EdgeInsets.only(bottom: 50),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _mentionSuggestions.length,
              itemBuilder: (context, index) {
                final member = _mentionSuggestions[index];
                final name = member['display_name'] as String? ?? 'Unknown';
                final username = member['username'] as String? ?? '';
                return ListTile(
                  dense: true,
                  leading: CircleAvatar(
                    radius: 16,
                    backgroundColor: const Color(0xFF00A884)
                        .withValues(alpha: 0.2),
                    child: Text(
                      name.isNotEmpty ? name[0].toUpperCase() : '?',
                      style: const TextStyle(
                        color: Color(0xFF00A884),
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  title: Text(name, style: const TextStyle(fontSize: 14)),
                  subtitle: username.isNotEmpty
                      ? Text('@$username', style: const TextStyle(fontSize: 12))
                      : null,
                  onTap: () => _insertMention(member),
                );
              },
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_mentionOverlay!);
  }

  void _hideMentionOverlay() {
    _mentionOverlay?.remove();
    _mentionOverlay = null;
    if (_showMentions) {
      setState(() => _showMentions = false);
    }
  }

  void _insertMention(Map<String, dynamic> member) {
    final username = member['username'] as String? ?? '';
    if (username.isEmpty) return;

    final text = _textController.text;
    final cursorPos = _textController.selection.baseOffset;
    final beforeCursor = text.substring(0, cursorPos);
    final lastAtIndex = beforeCursor.lastIndexOf('@');

    if (lastAtIndex >= 0) {
      final newText =
          '${beforeCursor.substring(0, lastAtIndex)}@$username ${text.substring(cursorPos)}';
      _textController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(
          offset: lastAtIndex + username.length + 2,
        ),
      );
    }
    _hideMentionOverlay();
    _focusNode.requestFocus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    chatRouteObserver.unsubscribe(this);
    _setVisible(false);
    _mentionOverlay?.remove();
    _textController.removeListener(_onTextChanged);
    _repo.removeListener(_onRepoChanged);
    _repo.dispose();
    _textController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    _typingPresence?.dispose();
    super.dispose();
  }

  void _onHistoryScroll() {
    unawaited(_markVisibleRead());
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
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _markVisibleRead());
  }

  Future<void> _initChat() async {
    final preferences = await SharedPreferences.getInstance();
    if (!mounted) return;
    final clearedRaw = preferences.getString(_clearedAtKey());
    if (mounted) {
      setState(() {
        _preferences = preferences;
        _clearedAt = clearedRaw == null ? null : DateTime.tryParse(clearedRaw);
        _wallpaperPreset = ChatPreferences(preferences)
            .wallpaperFor(widget.conversationId);
      });
    }
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
      _typingPresence?.setActive(
        NotifyService.instance.openGroups.contains(widget.conversationId),
      );
    }

    try {
      unawaited(_loadSenderAvatars());
      unawaited(_syncGroupMeta());
      final count = await _repo.loadMessages(widget.conversationId);
      if (!mounted) return;
      _hasMoreHistory = count == ConversationRepository.messagePageSize;
      if (widget.e2eeEnabled && !widget.readOnlyArchive) {
        await _repo.retryPendingGroupMessages(widget.conversationId);
      }
      if (!mounted) return;
      if (!widget.readOnlyArchive) {
        _repo.subscribeToConversation(widget.conversationId);
      } else {
        _hasMoreHistory = false;
      }
      if (mounted) {
        setState(() => _isLoading = false);
        WidgetsBinding.instance.addPostFrameCallback((_) => _markVisibleRead());
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
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
        final messageId = await _repo.sendMessage(
          widget.conversationId,
          text,
          parentMessageId: replyId,
        );
        unawaited(_repo.notifyGroup(widget.conversationId, messageId));
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

  Future<void> _chooseWallpaper() async {
    final preferences = _preferences;
    if (preferences == null) return;
    final picked = await chooseChatWallpaper(context, _wallpaperPreset);
    if (picked == null || !mounted) return;
    await ChatPreferences(preferences)
        .setWallpaper(widget.conversationId, picked);
    setState(() => _wallpaperPreset = picked);
  }

  void _showInvite() async {
    final conv = _repo.conversations
        .where((c) => c.id == widget.conversationId)
        .firstOrNull;
    if (conv == null || !conv.isAdmin) {
      _showToast('Only admins can invite members.');
      return;
    }
    final repo = ConversationRepository(Supabase.instance.client);
    String code;
    try {
      code = await repo.getGroupInviteCode(widget.conversationId);
    } catch (_) {
      _showToast('Could not generate invite link.');
      return;
    }
    final link = 'dev.openchat.openchat://group-invite/$code';
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Invite to group'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QrImageView(data: link, version: QrVersions.auto, size: 200),
            const SizedBox(height: 12),
            SelectableText(link, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            const Text(
              'Share this link to invite members. Only admins can reset it.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: link));
              Navigator.pop(ctx);
              _showToast('Invite link copied');
            },
            child: const Text('Copy link'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final confirm = await showDialog<bool>(
                context: context,
                builder: (c) => AlertDialog(
                  title: const Text('Reset invite link?'),
                  content: const Text(
                    'This will invalidate the current link and generate a new one. '
                    'Anyone with the old link will no longer be able to join.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(c, false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(c, true),
                      child: const Text('Reset'),
                    ),
                  ],
                ),
              );
              if (confirm != true) return;
              try {
                await repo.resetGroupInviteCode(widget.conversationId);
                if (!mounted) return;
                _showToast('Invite link reset');
              } catch (_) {
                if (!mounted) return;
                _showToast('Failed to reset invite link');
              }
            },
            child: const Text('Reset link'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  // Group Voice Chat methods - DISABLED: incomplete implementation
  // /// Start a group voice chat (drop-in audio).
  // Future<void> _startVoiceChat() async {
  //   final roomName = await _voiceChat.startVoiceChat(
  //     context: context,
  //     client: Supabase.instance.client,
  //     conversationId: widget.conversationId,
  //     conversationTitle: _title,
  //   );
  //   if (roomName != null && mounted) {
  //     _showToast('Voice chat started');
  //   }
  // }
  //
  // /// Join an existing group voice chat.
  // Future<void> _joinVoiceChat() async {
  //   final joined = await _voiceChat.joinVoiceChat(
  //     context: context,
  //     client: Supabase.instance.client,
  //     conversationId: widget.conversationId,
  //     conversationTitle: _title,
  //   );
  //   if (joined && mounted) {
  //     _showToast('Joined voice chat');
  //   }
  // }
  //
  // /// Leave the group voice chat.
  // Future<void> _leaveVoiceChat() async {
  //   await _voiceChat.leaveVoiceChat();
  //   if (mounted) {
  //     _showToast('Left voice chat');
  //   }
  // }

  String _clearedAtKey() =>
      'openchat.groupClearedAt.v1.$_currentUserId.${widget.conversationId}';

  Future<void> _toggleMute() async {
    GroupConversation? conv;
    for (final c in _repo.conversations) {
      if (c.id == widget.conversationId) {
        conv = c;
        break;
      }
    }
    final muted = conv?.isMutedNow ?? false;
    try {
      await _repo.setConversationFlags(widget.conversationId, muted: !muted);
      if (mounted) {
        _showToast(muted ? 'Notifications unmuted' : 'Notifications muted');
      }
    } catch (_) {
      if (mounted) _showToast('Could not update notifications.');
    }
  }

  Future<void> _searchInChat() async {
    final query = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController();
        return AlertDialog(
          title: const Text('Search in chat'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Search messages'),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('Search'),
            ),
          ],
        );
      },
    );
    if (query == null || query.trim().isEmpty || !mounted) return;
    final q = query.toLowerCase();
    final matches = _repo
        .messagesFor(widget.conversationId)
        .where((m) => m.content.toLowerCase().contains(q))
        .toList();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: matches.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Text('No matching messages.'),
              )
            : ListView.builder(
                shrinkWrap: true,
                itemCount: matches.length,
                itemBuilder: (ctx, i) => ListTile(
                  leading: const Icon(Icons.chat_bubble_outline),
                  title: Text(
                    matches[i].content,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${matches[i].createdAt.toLocal()}'.split('.').first,
                  ),
                ),
              ),
      ),
    );
  }

  Future<void> _showGroupMedia() async {
    final media = _repo
        .messagesFor(widget.conversationId)
        .where(
          (m) =>
              m.type == 'image' ||
              m.type == 'video' ||
              m.type == 'document' ||
              m.type == 'audio' ||
              (m.mediaUrl != null && m.mediaUrl!.isNotEmpty),
        )
        .toList();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: media.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Text('No media or documents yet.'),
              )
            : ListView.builder(
                shrinkWrap: true,
                itemCount: media.length,
                itemBuilder: (ctx, i) {
                  final m = media[i];
                  return ListTile(
                    leading: Icon(
                      m.type == 'video'
                          ? Icons.videocam_outlined
                          : m.type == 'audio'
                          ? Icons.mic_none
                          : m.type == 'document'
                          ? Icons.description_outlined
                          : Icons.image_outlined,
                    ),
                    title: Text(
                      m.mediaUrl ?? m.content,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(m.type),
                  );
                },
              ),
      ),
    );
  }

  Future<void> _clearChat() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear this chat?'),
        content: const Text(
          'Messages will be hidden on this device only. Other members keep '
          'their copy.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final now = DateTime.now().toUtc();
    await _preferences?.setString(_clearedAtKey(), now.toIso8601String());
    if (mounted) {
      setState(() => _clearedAt = now);
      _showToast('Chat cleared.');
    }
  }

  Future<void> _deleteGroup() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete group permanently?'),
        content: Text(
          '“$_title” and its messages will be deleted for all members. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete group'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _repo.deleteGroup(widget.conversationId);
      if (!mounted) return;
      // Close the member sheet and then the group screen.
      Navigator.of(context).pop();
      Navigator.of(context).pop();
    } catch (_) {
      if (mounted) _showToast('Could not delete group. Only its owner can.');
    }
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
        onReact: (emoji) => unawaited(
          _runMessageAction(
            () => _repo.reactToMessage(msg.id, emoji),
            success: 'Reaction updated.',
          ),
        ),
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
        onStar: () => unawaited(
          _runMessageAction(
            () => _repo.toggleStar(msg.id),
            success: msg.isStarred ? 'Message unstarred.' : 'Message starred.',
          ),
        ),
        onPin: () => unawaited(
          _runMessageAction(
            () => _repo.togglePin(widget.conversationId, msg.id),
            success: msg.isPinned ? 'Message unpinned.' : 'Message pinned.',
          ),
        ),
        onDeleteForMe: widget.e2eeEnabled
            ? null
            : () => unawaited(
                _runMessageAction(
                  () => _repo.deleteMessage(msg.id, forEveryone: false),
                  success: 'Message deleted for you.',
                ),
              ),
        onDeleteForEveryone: isMine
            ? () => unawaited(
                _runMessageAction(
                  () => _repo.deleteMessage(msg.id, forEveryone: true),
                  success: 'Message deleted for everyone.',
                ),
              )
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

  Future<void> _runMessageAction(
    Future<void> Function() action, {
    required String success,
  }) async {
    try {
      await action();
      if (mounted) _showToast(success);
    } catch (_) {
      if (mounted)
        _showToast(
          'Message action failed. Check your connection and try again.',
        );
    }
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
  Future<void> _addMembers() async {
    List<Map<String, dynamic>> roster = [];
    try {
      roster = await _repo.members(widget.conversationId);
    } catch (_) {}
    final existing = roster.map((m) => (m['user_id'] ?? '').toString()).toSet();
    List<CloudContact> contacts = [];
    try {
      contacts = await SupabaseContactsRepository(Supabase.instance.client)
          .contacts();
    } catch (_) {}
    final candidates = contacts
        .where(
          (c) => c.userId != _currentUserId && !existing.contains(c.userId),
        )
        .toList();
    if (!mounted) return;
    if (candidates.isEmpty) {
      _showToast('No contacts left to add.');
      return;
    }
    final selected = <String>{};
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Add members',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: candidates.length,
                  itemBuilder: (ctx, i) {
                    final c = candidates[i];
                    return CheckboxListTile(
                      value: selected.contains(c.userId),
                      onChanged: (v) => setSheet(() {
                        if (v == true) {
                          selected.add(c.userId);
                        } else {
                          selected.remove(c.userId);
                        }
                      }),
                      title: Text(c.name),
                      subtitle: Text('@${c.username}'),
                      secondary: CircleAvatar(
                        foregroundImage: (c.avatarUrl ?? '').isNotEmpty
                            ? NetworkImage(c.avatarUrl!)
                            : null,
                        child: Text(
                          c.name.isEmpty ? '?' : c.name[0].toUpperCase(),
                        ),
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: selected.isEmpty
                        ? null
                        : () => Navigator.pop(ctx, true),
                    child: Text('Add ${selected.length} member(s)'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    var added = 0;
    for (final id in selected) {
      try {
        await _repo.addMember(widget.conversationId, id);
        added++;
      } catch (_) {}
    }
    if (mounted) {
      _showToast('Added $added member(s).');
      await _showMembers();
    }
  }

  Future<void> _showMembers() async {
    List<Map<String, dynamic>> roster = [];
    String? error;
    try {
      roster = await _repo.members(widget.conversationId);
    } catch (_) {
      error = 'Could not load members. Check your connection.';
    }
    if (!mounted) return;
    setState(() => _memberCount = roster.length);
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
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
              child: Column(
                children: [
                  Stack(
                    alignment: Alignment.bottomRight,
                    children: [
                      CircleAvatar(
                        radius: 42,
                        backgroundColor: const Color(0xFF00A884)
                            .withValues(alpha: .14),
                        foregroundImage:
                            ((_groupAvatar ?? widget.avatarUrl) ?? '')
                                .isNotEmpty
                            ? NetworkImage(_groupAvatar ?? widget.avatarUrl!)
                            : null,
                        child:
                            ((_groupAvatar ?? widget.avatarUrl) ?? '').isEmpty
                            ? const Icon(
                                Icons.groups_rounded,
                                size: 38,
                                color: Color(0xFF00A884),
                              )
                            : null,
                      ),
                      if (canManage)
                        Material(
                          color: Theme.of(ctx).colorScheme.primary,
                          shape: const CircleBorder(),
                          child: IconButton(
                            tooltip: 'Change group photo',
                            visualDensity: VisualDensity.compact,
                            iconSize: 18,
                            color: Theme.of(ctx).colorScheme.onPrimary,
                            onPressed: () {
                              Navigator.pop(context);
                              _pickGroupPhoto();
                            },
                            icon: const Icon(Icons.camera_alt_outlined),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _title,
                    textAlign: TextAlign.center,
                    style: Theme.of(ctx).textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  if ((_description ?? '').trim().isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      _description!,
                      textAlign: TextAlign.center,
                      style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    '${roster.length} members · ${myRole == 'owner'
                        ? 'You own this group'
                        : myRole == 'admin'
                        ? 'Group admin'
                        : 'Group member'}',
                    style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      if (canManage)
                        ActionChip(
                          avatar: const Icon(Icons.edit_outlined, size: 18),
                          label: const Text('Edit'),
                          onPressed: () async {
                            Navigator.pop(context);
                            await _editGroupInfo();
                          },
                        ),
                      if (canManage)
                        ActionChip(
                          avatar: const Icon(Icons.person_add_alt_1, size: 18),
                          label: const Text('Add'),
                          onPressed: () async {
                            Navigator.pop(context);
                            await _addMembers();
                          },
                        ),
                      ActionChip(
                        avatar: const Icon(Icons.qr_code_2, size: 18),
                        label: const Text('Invite'),
                        onPressed: () {
                          Navigator.pop(context);
                          _showInvite();
                        },
                      ),
                    ],
                  ),
                ],
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
                          if (isMe && role != 'owner')
                            TextButton(
                              onPressed: () async {
                                final confirmed = await showDialog<bool>(
                                  context: ctx,
                                  builder: (dctx) => AlertDialog(
                                    title: const Text('Leave this group?'),
                                    content: const Text(
                                      'You will stop receiving new messages. '
                                      'An admin can add you back later.',
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
                                        child: const Text('Leave group'),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirmed != true) return;
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
                            )
                          else if (canManage &&
                              role != 'owner' &&
                              (role == 'member' || myRole == 'owner'))
                            PopupMenuButton<String>(
                              tooltip: 'Member options',
                              onSelected: (action) async {
                                if (action == 'remove') {
                                  final confirmed = await showDialog<bool>(
                                    context: ctx,
                                    builder: (dctx) => AlertDialog(
                                      title: Text('Remove $name?'),
                                      content: const Text(
                                        'They will stop receiving new '
                                        'messages.',
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
                                    await _showMembers();
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
                                  return;
                                }
                                if (action == 'transfer') {
                                  final confirmed = await showDialog<bool>(
                                    context: ctx,
                                    builder: (dctx) => AlertDialog(
                                      title: const Text('Transfer ownership?'),
                                      content: Text(
                                        '$name will become the owner, and you '
                                        'will remain a group admin.',
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
                                          child: const Text('Transfer'),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (confirmed != true) return;
                                  try {
                                    await _repo.transferOwnership(
                                      widget.conversationId,
                                      id,
                                    );
                                    if (!mounted) return;
                                    Navigator.pop(context);
                                    _showToast(
                                      'Ownership transferred to $name.',
                                    );
                                    await _showMembers();
                                  } catch (_) {
                                    if (ctx.mounted) {
                                      ScaffoldMessenger.of(ctx).showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'Could not transfer ownership.',
                                          ),
                                        ),
                                      );
                                    }
                                  }
                                  return;
                                }
                                final newRole = action == 'promote'
                                    ? 'admin'
                                    : 'member';
                                try {
                                  await _repo.setMemberRole(
                                    widget.conversationId,
                                    id,
                                    newRole,
                                  );
                                  if (!mounted) return;
                                  Navigator.pop(context);
                                  _showToast(
                                    action == 'promote'
                                        ? '$name is now an admin.'
                                        : '$name is now a member.',
                                  );
                                  await _showMembers();
                                } catch (_) {
                                  if (ctx.mounted) {
                                    ScaffoldMessenger.of(ctx).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          'Could not change that role.',
                                        ),
                                      ),
                                    );
                                  }
                                }
                              },
                              itemBuilder: (_) => [
                                if (role == 'member')
                                  const PopupMenuItem(
                                    value: 'promote',
                                    child: Text('Make group admin'),
                                  ),
                                if (role == 'admin' && myRole == 'owner')
                                  const PopupMenuItem(
                                    value: 'demote',
                                    child: Text('Dismiss as admin'),
                                  ),
                                if (myRole == 'owner' &&
                                    widget.conversationType == 'group')
                                  const PopupMenuItem(
                                    value: 'transfer',
                                    child: Text('Transfer ownership'),
                                  ),
                                if (role == 'member' ||
                                    (role == 'admin' && myRole == 'owner'))
                                  const PopupMenuItem(
                                    value: 'remove',
                                    child: Text('Remove from group'),
                                  ),
                              ],
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            if (myRole == 'owner' && widget.conversationType == 'group')
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                    ),
                    onPressed: _deleteGroup,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete group for everyone'),
                  ),
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
    final allMessages = _repo.messagesFor(widget.conversationId);
    final messages = _clearedAt == null
        ? allMessages
        : allMessages.where((m) => m.createdAt.isAfter(_clearedAt!)).toList();
    final pinnedMessages = messages.where((m) => m.isPinned).toList();

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: const Color(0xFF00A884).withValues(alpha: 0.2),
              backgroundImage: (_groupAvatar ?? widget.avatarUrl) != null
                  ? NetworkImage(_groupAvatar ?? widget.avatarUrl!)
                  : null,
              child: (_groupAvatar ?? widget.avatarUrl) == null
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
                      _title,
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
                          : _memberCount > 0
                          ? '$_memberCount members'
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
          if (!widget.readOnlyArchive)
            AnimatedBuilder(
              animation: _voiceChat,
              builder: (context, _) {
                final inRoom =
                    _voiceChat.isInRoom &&
                    _voiceChat.currentConversationId == widget.conversationId;
                final joining = _voiceChat.joining;
                return IconButton(
                  icon: joining
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          inRoom ? Icons.mic : Icons.mic_none,
                          color: inRoom ? const Color(0xFF25D366) : null,
                        ),
                  tooltip: inRoom ? 'Leave voice chat' : 'Start voice chat',
                  onPressed: joining
                      ? null
                      : (inRoom ? _leaveVoiceChat : _startVoiceChat),
                );
              },
            ),
          PopupMenuButton<String>(
            onSelected: (val) async {
              if (val == 'info') {
                await _showMembers();
              } else if (val == 'clear') {
                await _clearChat();
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
              } else if (val == 'media') {
                await _showGroupMedia();
              } else if (val == 'search') {
                await _searchInChat();
              } else if (val == 'mute') {
                await _toggleMute();
              } else if (val == 'wallpaper') {
                await _chooseWallpaper();
              } else if (val == 'invite') {
                _showInvite();
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
              const PopupMenuItem(
                value: 'wallpaper',
                child: Text('Chat wallpaper & theme'),
              ),
              const PopupMenuItem(
                value: 'invite',
                child: Text('Invite via link / QR'),
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
        preset: _wallpaperPreset,
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
            // Group voice chat banner: shown while a drop-in audio room is
            // ongoing for this conversation.
            AnimatedBuilder(
              animation: _voiceChat,
              builder: (context, _) {
                final room = _voiceChat.getRoom(widget.conversationId);
                if (room == null ||
                    !room.isActive ||
                    _dismissedVoiceRoom == widget.conversationId) {
                  return const SizedBox.shrink();
                }
                final inRoom =
                    _voiceChat.isInRoom &&
                    _voiceChat.currentConversationId == widget.conversationId;
                return GroupVoiceChatBanner(
                  conversationId: widget.conversationId,
                  conversationTitle: _title,
                  participantCount: room.participantCount,
                  isCurrentUserIn: inRoom,
                  onJoin: _joinVoiceChat,
                  onLeave: _leaveVoiceChat,
                  onDismiss: () =>
                      setState(() => _dismissedVoiceRoom = widget.conversationId),
                );
              },
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

    Widget bubble = Align(
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

    // Wrap with Dismissible for swipe-to-reply
    return Dismissible(
      key: ValueKey(msg.id),
      direction: isMine ? DismissDirection.startToEnd : DismissDirection.endToStart,
      background: _groupReplySwipeBackground(isMine: isMine, isDark: isDark),
      onDismissed: (_) => _startReply(msg),
      child: bubble,
    );
  }

  Widget _groupReplySwipeBackground({required bool isMine, required bool isDark}) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF004D3A) : const Color(0xFFDCF8C6),
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: isMine ? Alignment.centerLeft : Alignment.centerRight,
      child: Icon(
        Icons.reply,
        color: isDark ? const Color(0xFF25D366) : const Color(0xFF008069),
        size: 28,
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
                      child: CompositedTransformTarget(
                        link: _mentionLayerLink,
                        child: TextField(
                          controller: _textController,
                          focusNode: _focusNode,
                          maxLines: 5,
                          minLines: 1,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: const InputDecoration(
                            hintText: 'Message (@ to mention)',
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(vertical: 8),
                          ),
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
  RealtimeChannel? _votesChannel;

  @override
  void initState() {
    super.initState();
    _load();
    try {
      _votesChannel = Supabase.instance.client.channel('poll:${widget.msg.id}')
        ..onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'poll_votes',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'message_id',
            value: widget.msg.id,
          ),
          callback: (_) => _load(),
        )
        ..subscribe();
    } catch (_) {}
  }

  @override
  void dispose() {
    try {
      _votesChannel?.unsubscribe();
    } catch (_) {}
    super.dispose();
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
