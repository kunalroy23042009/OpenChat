import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_store.dart';
import 'chat_lock.dart';
import 'contacts_repository.dart';
import 'local_profile.dart';
import 'media/media_message.dart';
import 'push/push_service.dart';
import 'secure_chat_screen.dart';
import 'settings.dart';
import 'theme/app_theme.dart';
import 'status/status_page.dart';
import 'calling/call_history_page.dart';
import 'calling/call_repository.dart';
import 'calling/call_service.dart';
import 'calling/call_signaling.dart';
import 'calling/call_screen.dart';
import 'ai/ai_settings_page.dart';
import 'widgets/whatsapp_bubble.dart';
import 'widgets/status_ticks.dart';

class ChatHome extends StatefulWidget {
  const ChatHome({
    super.key,
    required this.store,
    required this.profile,
    required this.push,
    this.client,
    this.startupError,
    this.theme,
  });
  final ChatStore store;
  final LocalProfile profile;
  final PushService push;
  final SupabaseClient? client;
  final String? startupError;
  final AppThemeController? theme;
  @override
  State<ChatHome> createState() => _ChatHomeState();
}

class _ChatHomeState extends State<ChatHome> {
  Conversation? selected;
  String query = '';
  String filter = 'all';
  bool lockRevealed = false;
  RealtimeChannel? _callWatch;
  String? _callWatchUid;
  bool _incomingOpen = false;
  int activeTab = 0;
  void open(Conversation chat, bool wide) {
    widget.store.markRead(chat);
    if (wide) {
      setState(() => selected = chat);
    } else {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: SafeArea(
              child: ChatPane(
                store: widget.store,
                chat: chat,
                onBack: () => Navigator.pop(context),
              ),
            ),
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    _callWatch?.unsubscribe();
    super.dispose();
  }

  /// Foreground incoming-call ringer. While signed in, watch our invite
  /// rows; an unanswered ring also needs the app open (background ringing
  /// arrives with push notifications).
  void _watchIncomingCalls(BuildContext context) {
    final client = widget.client;
    final uid = client?.auth.currentUser?.id;
    if (uid == null) {
      _callWatch?.unsubscribe();
      _callWatch = null;
      _callWatchUid = null;
      return;
    }
    if (_callWatchUid == uid && _callWatch != null) return;
    _callWatch?.unsubscribe();
    _callWatchUid = uid;
    _callWatch =
        client!.channel('calls:$uid')
          ..onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'call_invites',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'callee_id',
              value: uid,
            ),
            callback: (payload) => _onIncomingInvite(payload.newRecord),
          )
          ..subscribe();
  }

  Future<void> _onIncomingInvite(Map<String, dynamic> record) async {
    if (!mounted || _incomingOpen) return;
    if (record['status'] != 'ringing') return;
    final created = DateTime.tryParse(record['created_at'] as String? ?? '');
    if (created != null &&
        DateTime.now().difference(created) > const Duration(seconds: 75)) {
      return;
    }
    final inviteId = record['id'] as String? ?? '';
    final callerId = record['caller_id'] as String? ?? '';
    final callType = record['call_type'] as String? ?? 'voice';
    if (inviteId.isEmpty || callerId.isEmpty) return;
    final client = widget.client!;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    String peerName = 'Unknown caller';
    try {
      final contacts = await SupabaseContactsRepository(client).contacts();
      for (final c in contacts) {
        if (c.userId == callerId) {
          peerName = c.name;
          break;
        }
      }
    } catch (_) {}
    if (!mounted || _incomingOpen) return;
    _incomingOpen = true;
    final accept = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text('Incoming ${callType == 'video' ? 'video' : 'voice'} call'),
        content: Text(peerName),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Decline'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.call),
            label: const Text('Accept'),
          ),
        ],
      ),
    );
    _incomingOpen = false;
    if (!mounted) return;
    if (accept != true) {
      try {
        await CallSignaling.answer(
          client,
          inviteId: inviteId,
          accept: false,
        );
        await CallRepository(client).add(
          peerLabel: peerName,
          peerId: callerId,
          callType: callType,
          outcome: 'declined',
          startedAt: DateTime.now(),
          durationSeconds: 0,
          direction: 'incoming',
        );
      } catch (_) {}
      return;
    }
    final service = CallService();
    if (!await service.ensurePermissions(
      video: callType == 'video',
    )) {
      messenger.showSnackBar(
        SnackBar(content: Text(service.error ?? 'Permission denied.')),
      );
      service.dispose();
      try {
        await CallSignaling.answer(client, inviteId: inviteId, accept: false);
      } catch (_) {}
      return;
    }
    late final String url;
    late final String token;
    try {
      final creds = await CallSignaling.token(
        client,
        room: record['room'] as String? ?? '',
        name: peerName,
      );
      url = creds.url;
      token = creds.token;
      await CallSignaling.answer(client, inviteId: inviteId, accept: true);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
      service.dispose();
      return;
    }
    if (!await service.join(
      url: url,
      token: token,
      video: callType == 'video',
    )) {
      messenger.showSnackBar(
        SnackBar(content: Text(service.error ?? 'Could not join the call.')),
      );
      try {
        await CallSignaling.finish(client, inviteId: inviteId);
      } catch (_) {}
      service.dispose();
      return;
    }
    final session = ActiveCallSession(
      callId: inviteId,
      peerUsername: peerName,
      peerDisplayName: peerName,
      type: callType == 'video' ? CallType.video : CallType.voice,
      initialState: CallState.connected,
    );
    final startedAt = DateTime.now();
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => CallScreen(
          session: session,
          service: service,
          onEndCall: () async {
            try {
              await CallSignaling.finish(client, inviteId: inviteId);
            } catch (_) {}
            await service.hangUp();
            try {
              await CallRepository(client).add(
                peerLabel: peerName,
                peerId: callerId,
                callType: callType,
                outcome: session.durationSeconds > 0 ? 'completed' : 'failed',
                startedAt: startedAt,
                durationSeconds: session.durationSeconds,
                direction: 'incoming',
              );
            } catch (_) {}
            service.dispose();
            try {
              navigator.pop();
            } catch (_) {}
          },
        ),
      ),
    );
  }

  Future<void> newChat(bool wide) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _NewChatDialog(),
    );
    if (name == null || !mounted) return;
    final chat = await widget.store.create(name);
    if (mounted) open(chat, wide);
  }

  /// WhatsApp-style long-press menu: pin, favourite, lock, archive, delete.
  Future<void> _chatActions(Conversation chat) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                chat.pinned ? Icons.push_pin : Icons.push_pin_outlined,
              ),
              title: Text(chat.pinned ? 'Unpin chat' : 'Pin to top'),
              onTap: () => Navigator.pop(ctx, 'pin'),
            ),
            ListTile(
              leading: Icon(
                chat.favourite ? Icons.star : Icons.star_outline,
              ),
              title: Text(
                chat.favourite ? 'Remove from favourites' : 'Add to favourites',
              ),
              onTap: () => Navigator.pop(ctx, 'favourite'),
            ),
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: Text(chat.locked ? 'Unlock chat' : 'Lock chat'),
              subtitle: chat.locked
                  ? null
                  : const Text('Needs a chat lock PIN from Settings.'),
              onTap: () => Navigator.pop(ctx, 'lock'),
            ),
            ListTile(
              leading: const Icon(Icons.archive_outlined),
              title: Text(chat.archived ? 'Unarchive' : 'Archive'),
              onTap: () => Navigator.pop(ctx, 'archive'),
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(ctx).colorScheme.error,
              ),
              title: const Text('Delete'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    final store = widget.store;
    switch (action) {
      case 'pin':
        await store.setPinned(chat.id, !chat.pinned);
      case 'favourite':
        await store.setFavourite(chat.id, !chat.favourite);
      case 'lock':
        if (chat.locked) {
          await store.setLocked(chat.id, false);
        } else if (!await ChatLock.hasPin()) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Set a chat lock PIN in Settings first.'),
            ),
          );
        } else {
          await store.setLocked(chat.id, true);
          setState(() => lockRevealed = false);
        }
      case 'archive':
        await store.setArchived(chat.id, !chat.archived);
      case 'delete':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Delete "${chat.name}"?'),
            content: const Text(
              'This removes the conversation from this device forever. Encrypted cloud chats are unaffected.',
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
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          await store.deleteConversation(chat.id);
        }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        _watchIncomingCalls(context);
        final wide = constraints.maxWidth >= 850;
        final viewingArchived = filter == 'archived';
        final base = widget.store.conversations.where((c) {
          if (!c.name.toLowerCase().contains(query.toLowerCase())) {
            return false;
          }
          if (viewingArchived != c.archived) return false;
          if (filter == 'unread' && c.unread == 0) return false;
          if (filter == 'favourites' && !c.favourite) return false;
          if (c.locked && !lockRevealed) return false;
          return true;
        }).toList();
        // Pinned first, otherwise stable insertion order.
        final indexed = base.asMap().entries.toList();
        indexed.sort((a, b) {
          if (a.value.pinned != b.value.pinned) {
            return a.value.pinned ? -1 : 1;
          }
          return a.key.compareTo(b.key);
        });
        final chats = [for (final e in indexed) e.value];
        final lockedCount = widget.store.conversations
            .where((c) => c.locked && !c.archived)
            .length;
        final list = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 16, 12),
              child: Row(
                children: [
                  Semantics(
                    label: 'OpenChat logo',
                    image: true,
                    child: Image.asset(
                      Theme.of(context).brightness == Brightness.dark
                          ? 'assets/logos/openchat_dove_white.png'
                          : 'assets/logos/openchat_dove.png',
                      width: 30,
                      height: 30,
                      fit: BoxFit.contain,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'OpenChat',
                      style: TextStyle(
                        fontSize: 27,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -1.2,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'AI Assistants (ChatGPT, Claude, Gemini)',
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => AiSettingsPage(store: widget.store),
                      ),
                    ),
                    icon: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: [
                            Color(0xFF245CDB),
                            Color(0xFF00C6FF),
                            Color(0xFF9D50BB),
                          ],
                        ),
                      ),
                      child: const Icon(
                        Icons.auto_awesome,
                        size: 18,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Settings and account',
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => SettingsPage(
                          store: widget.store,
                          profile: widget.profile,
                          push: widget.push,
                          client: widget.client,
                          startupError: widget.startupError,
                          theme: widget.theme,
                        ),
                      ),
                    ),
                    icon: const Icon(Icons.tune_rounded),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'A little closer, wherever you are.',
                style: TextStyle(color: Color(0xFF66748A)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: TextField(
                onChanged: (v) => setState(() => query = v),
                decoration: const InputDecoration(
                  hintText: 'Search conversations',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ChoiceChip(
                    label: const Text('All chats'),
                    selected: filter == 'all',
                    onSelected: (_) => setState(() => filter = 'all'),
                  ),
                  ChoiceChip(
                    label: const Text('Unread'),
                    selected: filter == 'unread',
                    onSelected: (_) => setState(() => filter = 'unread'),
                  ),
                  ChoiceChip(
                    label: const Text('Favourites'),
                    selected: filter == 'favourites',
                    onSelected: (_) => setState(() => filter = 'favourites'),
                  ),
                  ChoiceChip(
                    label: const Text('Archived'),
                    selected: filter == 'archived',
                    onSelected: (_) => setState(() => filter = 'archived'),
                  ),
                  IconButton(
                    tooltip: 'New conversation',
                    onPressed: () => newChat(wide),
                    icon: const Icon(Icons.edit_square),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (widget.client?.auth.currentUser != null)
              _SecureSection(
                client: widget.client!,
                store: widget.store,
                profile: widget.profile,
                push: widget.push,
              ),
            if (lockedCount > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const CircleAvatar(
                    child: Icon(Icons.lock_outline, size: 20),
                  ),
                  title: Text(
                    lockRevealed
                        ? 'Hide locked chats'
                        : 'Locked chats ($lockedCount)',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: lockRevealed
                      ? null
                      : const Text('Verify your PIN to reveal them.'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    if (lockRevealed) {
                      setState(() => lockRevealed = false);
                      return;
                    }
                    if (await ChatLock.promptVerify(context)) {
                      if (!mounted) return;
                      setState(() => lockRevealed = true);
                    }
                  },
                ),
              ),
            Expanded(
              child: chats.isEmpty
                  ? const Center(
                      child: Text(
                        'No conversations found.\nStart a chat with the compose button.',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.builder(
                      itemCount: chats.length,
                      itemBuilder: (context, i) {
                        final chat = chats[i];
                        return Dismissible(
                          key: ValueKey(chat.id),
                          direction: DismissDirection.endToStart,
                          background: Container(
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 24),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primary,
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: const Icon(
                              Icons.archive_outlined,
                              color: Colors.white,
                            ),
                          ),
                          onDismissed: (_) async {
                            await widget.store.setArchived(chat.id, true);
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    '${chat.name} archived.',
                                  ),
                                  action: SnackBarAction(
                                    label: 'Undo',
                                    onPressed: () => widget.store.setArchived(
                                      chat.id,
                                      false,
                                    ),
                                  ),
                                ),
                              );
                            }
                          },
                          child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 3,
                          ),
                          child: Material(
                            color: selected == chat && wide
                                ? const Color(0xFFE8EEFD)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(18),
                            child: ListTile(
                              contentPadding: const EdgeInsets.all(12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(18),
                              ),
                              leading: ContactAvatar(chat: chat),
                              title: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      chat.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  if (chat.pinned)
                                    const Padding(
                                      padding: EdgeInsets.only(left: 4),
                                      child: Icon(
                                        Icons.push_pin_outlined,
                                        size: 14,
                                        color: Color(0xFF66748A),
                                      ),
                                    ),
                                  if (chat.favourite)
                                    const Padding(
                                      padding: EdgeInsets.only(left: 4),
                                      child: Icon(
                                        Icons.star,
                                        size: 14,
                                        color: Color(0xFFF59E0B),
                                      ),
                                    ),
                                  if (chat.locked)
                                    const Padding(
                                      padding: EdgeInsets.only(left: 4),
                                      child: Icon(
                                        Icons.lock_outline,
                                        size: 14,
                                        color: Color(0xFF66748A),
                                      ),
                                    ),
                                ],
                              ),
                              subtitle: Padding(
                                padding: const EdgeInsets.only(top: 5),
                                child: Text(
                                  chat.messages.isEmpty
                                      ? 'Say hello'
                                      : chat.messages.last.text,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              trailing: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    chat.messages.isEmpty
                                        ? ''
                                        : timeLabel(chat.messages.last.at),
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFF66748A),
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  if (chat.muted)
                                    const Padding(
                                      padding: EdgeInsets.only(bottom: 4),
                                      child: Icon(
                                        Icons.volume_off,
                                        size: 14,
                                        color: Color(0xFF66748A),
                                      ),
                                    ),
                                  if (chat.unread > 0)
                                    CircleAvatar(
                                      radius: 10,
                                      backgroundColor: const Color(0xFF245CDB),
                                      child: Text(
                                        '${chat.unread}',
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              onTap: () => open(chat, wide),
                              onLongPress: () => _chatActions(chat),
                            ),
                          ),
                        ));
                      },
                    ),
            ),
            if (widget.store.storageWarning != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  widget.store.storageWarning!,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
          ],
        );
        final currentBody = switch (activeTab) {
          1 => StatusPage(client: widget.client),
          2 => CallHistoryPage(client: widget.client),
          3 => SettingsPage(
            store: widget.store,
            profile: widget.profile,
            push: widget.push,
            client: widget.client,
            startupError: widget.startupError,
            theme: widget.theme,
          ),
          _ => list,
        };

        return Scaffold(
          body: SafeArea(
            child: wide
                ? Row(
                    children: [
                      SizedBox(width: 370, child: list),
                      const VerticalDivider(width: 1),
                      Expanded(
                        child:
                            selected != null &&
                                widget.store.conversations.contains(selected)
                            ? ChatPane(
                                key: ValueKey(selected!.id),
                                store: widget.store,
                                chat: selected!,
                              )
                            : const _Welcome(),
                      ),
                    ],
                  )
                : currentBody,
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: activeTab,
            onDestinationSelected: (index) {
              setState(() => activeTab = index);
            },
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.chat_outlined),
                selectedIcon: Icon(Icons.chat),
                label: 'Chats',
              ),
              NavigationDestination(
                icon: Icon(Icons.donut_large_outlined),
                selectedIcon: Icon(Icons.donut_large),
                label: 'Status',
              ),
              NavigationDestination(
                icon: Icon(Icons.call_outlined),
                selectedIcon: Icon(Icons.call),
                label: 'Calls',
              ),
              NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: 'Settings',
              ),
            ],
          ),
        );
      },
    ),
  );
}

class _NewChatDialog extends StatefulWidget {
  const _NewChatDialog();
  @override
  State<_NewChatDialog> createState() => _NewChatDialogState();
}

class _NewChatDialogState extends State<_NewChatDialog> {
  final controller = TextEditingController();
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void submit() {
    if (controller.text.trim().isNotEmpty) {
      Navigator.pop(context, controller.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New demo conversation'),
    content: TextField(
      controller: controller,
      autofocus: true,
      maxLength: 60,
      decoration: const InputDecoration(labelText: 'Contact name'),
      onSubmitted: (_) => submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: submit, child: const Text('Create')),
    ],
  );
}

class ContactAvatar extends StatelessWidget {
  const ContactAvatar({super.key, required this.chat});
  final Conversation chat;
  @override
  Widget build(BuildContext context) => CircleAvatar(
    radius: 25,
    backgroundColor: Color(chat.color),
    child: chat.isAi
        ? const Icon(Icons.auto_awesome, color: Colors.white, size: 22)
        : Text(
            chat.initials,
            style: const TextStyle(
              color: Color(0xFF23344F),
              fontWeight: FontWeight.w700,
              fontSize: 16,
            ),
          ),
  );
}

String timeLabel(DateTime at) =>
    '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';

/// Cloud-backed encrypted conversations for accepted contacts. Visible only
/// when signed in; the local demo list below stays for everyone.
class _SecureSection extends StatefulWidget {
  const _SecureSection({
    required this.client,
    required this.store,
    required this.profile,
    required this.push,
  });
  final SupabaseClient client;
  final ChatStore store;
  final LocalProfile profile;
  final PushService push;
  @override
  State<_SecureSection> createState() => _SecureSectionState();
}

class _SecureRow {
  const _SecureRow({required this.contact, required this.preview, this.at});
  final CloudContact contact;
  final String preview;
  final DateTime? at;
}

class _SecureSectionState extends State<_SecureSection> {
  late Future<List<_SecureRow>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<_SecureRow>> _load() async {
    final me = widget.client.auth.currentUser?.id;
    final contacts =
        (await SupabaseContactsRepository(widget.client).contacts())
            .where((c) => c.status == 'accepted')
            .toList();
    return [for (final c in contacts) _row(me, c)];
  }

  /// Last-message preview so encrypted chats feel persistent: text
  /// snippet, media/poll glyphs, or the invite hint when empty.
  _SecureRow _row(String? me, CloudContact contact) {
    final fallback = '@${contact.username} • end-to-end encrypted';
    if (me == null) {
      return _SecureRow(contact: contact, preview: fallback);
    }
    final msgs = widget.store.getSecureConversation(me, contact.userId);
    if (msgs.isEmpty) {
      return _SecureRow(contact: contact, preview: fallback);
    }
    final last = msgs.last;
    final body = parseMessageBody(last.text);
    final String preview;
    if (body.isImage) {
      preview = '📷 ${body.text.isEmpty ? 'Photo' : body.text}';
    } else if (body.isVideo) {
      preview = '🎬 ${body.text.isEmpty ? 'Video' : body.text}';
    } else if (body.isPoll) {
      preview = '📊 ${body.question ?? 'Poll'}';
    } else if (body.isVote) {
      preview = '🗳️ Voted in a poll';
    } else if (body.text.length > 60) {
      preview = '${body.text.substring(0, 60)}…';
    } else {
      preview = body.text;
    }
    return _SecureRow(
      contact: contact,
      preview: '${last.mine ? 'You: ' : ''}$preview',
      at: last.at,
    );
  }

  void _refresh() => setState(() => _future = _load());

  void _open(CloudContact contact) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SecureChatScreen(
          profile: widget.profile,
          store: widget.store,
          push: widget.push,
          client: widget.client,
          peerId: contact.userId,
          peerName: contact.name,
          peerUsername: contact.username,
        ),
      ),
    ).then((_) => _refresh());
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.lock_outline, size: 16, color: Color(0xFF245CDB)),
            const SizedBox(width: 6),
            const Text(
              'Encrypted chats',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
              ),
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Refresh encrypted chats',
              visualDensity: VisualDensity.compact,
              onPressed: _refresh,
              icon: const Icon(Icons.refresh, size: 18),
            ),
          ],
        ),
        FutureBuilder<List<_SecureRow>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: LinearProgressIndicator(),
              );
            }
            if (snapshot.hasError) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  'Could not load encrypted chats. Pull to retry with the refresh button.',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF66748A),
                  ),
                ),
              );
            }
            final chats = snapshot.data ?? const <_SecureRow>[];
            if (chats.isEmpty) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  'No encrypted chats yet. Add someone in Settings → People & profile, then open their encrypted chat here.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF66748A)),
                ),
              );
            }
            return SizedBox(
              height: 72.0 * chats.length.clamp(1, 3),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: chats.length,
                itemBuilder: (context, i) {
                  final row = chats[i];
                  final contact = row.contact;
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      backgroundColor: const Color(0xFFE4EBFF),
                      child: Text(
                        contact.name.isEmpty
                            ? '?'
                            : contact.name[0].toUpperCase(),
                        style: const TextStyle(
                          color: Color(0xFF245CDB),
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    title: Text(
                      contact.name,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      row.preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (row.at != null)
                          Text(
                            timeLabel(row.at!),
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF66748A),
                            ),
                          ),
                        const Icon(Icons.chevron_right),
                      ],
                    ),
                    onTap: () => _open(contact),
                  );
                },
              ),
            );
          },
        ),
        const Divider(height: 16),
      ],
    ),
  );
}

class _Welcome extends StatelessWidget {
  const _Welcome();
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(30),
            decoration: const BoxDecoration(
              color: Color(0xFFE4EBFF),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.waving_hand_rounded,
              size: 60,
              color: Color(0xFF245CDB),
            ),
          ),
          const SizedBox(height: 28),
          const Text(
            'Good conversations\nstart with a hello.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 36,
              height: 1.15,
              fontWeight: FontWeight.w800,
              letterSpacing: -1.2,
            ),
          ),
          const SizedBox(height: 18),
          const Text(
            'Choose a conversation, or make a new connection.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF66748A)),
          ),
          const SizedBox(height: 40),
          const Text(
            'PHASE 1 / LOCAL DEMO',
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 2,
              color: Color(0xFF66748A),
            ),
          ),
        ],
      ),
    ),
  );
}

class ChatPane extends StatefulWidget {
  const ChatPane({
    super.key,
    required this.store,
    required this.chat,
    this.onBack,
  });
  final ChatStore store;
  final Conversation chat;
  final VoidCallback? onBack;
  @override
  State<ChatPane> createState() => _ChatPaneState();
}

class _ChatPaneState extends State<ChatPane> {
  final composer = TextEditingController();
  final scroll = ScrollController();
  @override
  void dispose() {
    composer.dispose();
    scroll.dispose();
    super.dispose();
  }

  void send() {
    if (composer.text.trim().isEmpty) return;
    widget.store.send(widget.chat, composer.text);
    composer.clear();
    if (scroll.hasClients) scroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Row(
          children: [
            if (widget.onBack != null)
              IconButton(
                tooltip: 'Back',
                onPressed: widget.onBack,
                icon: const Icon(Icons.arrow_back),
              ),
            ContactAvatar(chat: widget.chat),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.chat.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 18,
                    ),
                  ),
                  Text(
                    widget.chat.isAi
                        ? (widget.chat.isTyping
                              ? 'Thinking…'
                              : 'AI Assistant (${widget.chat.aiProvider ?? "OpenChat"})')
                        : 'Demo contact',
                    style: TextStyle(
                      color: widget.chat.isTyping
                          ? const Color(0xFF245CDB)
                          : const Color(0xFF66748A),
                      fontSize: 12,
                      fontWeight: widget.chat.isTyping
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: widget.chat.muted
                  ? 'Unmute conversation'
                  : 'Mute conversation',
              onPressed: () {
                widget.store.toggleMute(widget.chat);
                setState(() {});
              },
              icon: Icon(
                widget.chat.muted
                    ? Icons.volume_off_outlined
                    : Icons.notifications_outlined,
              ),
            ),
            IconButton(
              tooltip: 'Voice call',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => CallScreen(
                      session: ActiveCallSession(
                        callId: DateTime.now().millisecondsSinceEpoch
                            .toString(),
                        peerUsername: widget.chat.id,
                        peerDisplayName: widget.chat.name,
                        type: CallType.voice,
                      ),
                      onEndCall: () => Navigator.pop(context),
                    ),
                  ),
                );
              },
              icon: const Icon(Icons.call_outlined),
            ),
            IconButton(
              tooltip: 'Video call',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => CallScreen(
                      session: ActiveCallSession(
                        callId: DateTime.now().millisecondsSinceEpoch
                            .toString(),
                        peerUsername: widget.chat.id,
                        peerDisplayName: widget.chat.name,
                        type: CallType.video,
                      ),
                      onEndCall: () => Navigator.pop(context),
                    ),
                  ),
                );
              },
              icon: const Icon(Icons.videocam_outlined),
            ),
          ],
        ),
      ),
      Container(
        width: double.infinity,
        color: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF182229)
            : const Color(0xFFEBF0FC),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Text(
            widget.chat.isAi
                ? '🔒 AI Assistant • Connected via ${widget.chat.aiProvider ?? "OpenChat"} LLM'
                : '💬 Demo conversation · stored only on this device',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.white70
                : const Color(0xFF465C85),
          ),
        ),
      ),
      Expanded(
        child: Container(
          decoration: BoxDecoration(
            color: Theme.of(context).brightness == Brightness.dark
                ? const Color(0xFF0B141A)
                : const Color(0xFFEFEAE2),
          ),
          child: ListenableBuilder(
            listenable: widget.store,
            builder: (context, _) {
              final messages = widget.chat.messages.reversed.toList();
              if (messages.isEmpty && !widget.chat.isTyping) {
                return const Center(
                  child: Text('Your conversation starts here. Say hello!'),
                );
              }
              final totalCount =
                  messages.length + (widget.chat.isTyping ? 1 : 0);
              return ListView.builder(
                controller: scroll,
                reverse: true,
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 16,
                ),
                itemCount: totalCount,
                itemBuilder: (context, i) {
                  if (widget.chat.isTyping && i == 0) {
                    return Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.only(left: 12, bottom: 8),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context).brightness == Brightness.dark
                              ? const Color(0xFF202C33)
                              : Colors.white,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 8),
                            Text(
                              'Thinking…',
                              style: TextStyle(
                                fontSize: 13,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }
                  final messageIndex = widget.chat.isTyping ? i - 1 : i;
                  final message = messages[messageIndex];
                  return WhatsAppBubble(
                    text: message.text,
                    isMine: message.mine,
                    timestamp: message.at,
                    status: MessageDeliveryState.read,
                  );
                },
              );
            },
          ),
        ),
      ),
      Container(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF1F2C34)
              : const Color(0xFFF0F2F5),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              icon: const Icon(
                Icons.emoji_emotions_outlined,
                color: Colors.grey,
              ),
              onPressed: () async {
                const choices = ['😀', '😂', '❤️', '👍', '🎉', '🙏'];
                final emoji = await showDialog<String>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Choose emoji'),
                    content: Wrap(
                      spacing: 14,
                      children: choices
                          .map(
                            (value) => InkWell(
                              onTap: () => Navigator.pop(context, value),
                              child: Text(
                                value,
                                style: const TextStyle(fontSize: 30),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                );
                if (emoji != null) {
                  composer.text += emoji;
                  composer.selection = TextSelection.collapsed(
                    offset: composer.text.length,
                  );
                }
              },
            ),
            IconButton(
              icon: const Icon(Icons.attach_file, color: Colors.grey),
              onPressed: () {
                showModalBottomSheet<void>(
                  context: context,
                  backgroundColor: Colors.transparent,
                  builder: (_) => WhatsAppAttachmentSheet(
                    onPick: (label) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Selected attachment: $label')),
                      );
                    },
                  ),
                );
              },
            ),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xFF2A3942)
                      : Colors.white,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: TextField(
                  controller: composer,
                  minLines: 1,
                  maxLines: 5,
                  maxLength: 4000,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    hintText: 'Write a message…',
                    counterText: '',
                    border: InputBorder.none,
                    filled: false,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                  ),
                  onSubmitted: (_) => send(),
                ),
              ),
            ),
            const SizedBox(width: 6),
            CircleAvatar(
              radius: 22,
              backgroundColor: const Color(0xFF00A884),
              child: IconButton(
                tooltip: 'Send message',
                onPressed: send,
                icon: const Icon(Icons.send, color: Colors.white, size: 20),
              ),
            ),
          ],
        ),
      ),
    ],
  );
}
