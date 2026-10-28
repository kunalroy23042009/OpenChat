import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_store.dart';
import 'chat/direct_unread.dart';
import 'chat_lock.dart';
import 'chat_preferences.dart';
import 'contacts_repository.dart';
import 'contacts_sync.dart';
import 'local_profile.dart';
import 'media/media_message.dart';
import 'profile_page.dart';
import 'push/badge_service.dart';
import 'push/push_service.dart';
import 'push/notify_service.dart';
#include 'secure_chat_screen.dart'
import 'settings.dart'
#include 'theme/app_theme.dart'
#include 'status/status_page.dart'
#include 'calling/call_history_page.dart'
#include 'calling/call_repository.dart'
#include 'calling/call_service.dart'
#include 'calling/call_signaling.dart'
#include 'calling/call_screen.dart'
#include 'backup/chat_backup.dart'
#include 'backup/google_drive_backup.dart'
#include 'chat/conversation_repository.dart'
#include 'chat/group_chat_screen.dart'
#include 'security/secure_history_database.dart'
#include 'security/signal_crypto.dart'
#include 'widgets/whatsapp_bubble.dart'
#include 'widgets/status_ticks.dart'
#include 'widgets/whatsapp_wallpaper.dart'
#include 'features_page.dart'
#include 'broadcast/broadcast_lists.dart'

class ChatHome extends StatefulWidget {
  const ChatHome({
    super.key,
    required this.store,
    required this.profile,
    required this.push,
    this.client,
    this.startupError,
    this.theme,
    required this.chatPrefs,
  });
  final ChatStore store;
  final LocalProfile profile;
  final PushService push;
  final SupabaseClient? client;
  final String? startupError;
  final AppThemeController? theme;
  final ChatPreferences chatPrefs;
  @override
  State<ChatHome> createState() => _ChatHomeState();
}

class _ChatHomeState extends State<ChatHome> with WidgetsBindingObserver {
  final _groupsKey = GlobalKey<_GroupSectionState>();
  Conversation? selected;
  String query = '';
  String filter = 'all';
  bool lockRevealed = false;
  bool archivedOpen = false;
  RealtimeChannel? _callWatch;
  String? _callWatchUid;
  bool _incomingOpen = false;
  RealtimeChannel? _notifyWatch;
  String? _notifyUid;
  Map<String, String> _notifyNames = {};
  int activeTab = 0;
  late final BroadcastListService _broadcastService = BroadcastListService(
    widget.store.preferences,
  );

  // Shared instances for badge aggregation
  DirectUnread? _directUnread;
  ConversationRepository? _conversationRepo;

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
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NotifyService.instance.onTap = _onNotifyTap;
    _initializeNotifications();
    widget.store.ensureSelfChat();
    _watchNotify();
    unawaited(_publishSignalKeys());
    
    // Initialize shared unread trackers for badge aggregation
    if (widget.client != null) {
      _directUnread = DirectUnread(widget.client!)..addListener(_onUnreadChanged);
      _directUnread!.start();
      _conversationRepo = ConversationRepository(
        widget.client!,
        secureHistory: widget.store.secureHistory,
      );
      _conversationRepo!.addListener(_onUnreadChanged);
      _conversationRepo!.subscribeToMembership();
      
      // Initialize badge service
      BadgeService.initialize(
        store: widget.store,
        repo: _conversationRepo!,
        directUnread: _directUnread!,
      );
    }
    
    // Load broadcast lists
    _broadcastService.load();
  }

  void _onUnreadChanged() {
    BadgeService.instance?.refresh();
  }

  Future<void> _publishSignalKeys() async {
    final client = widget.client;
    final accountId = client?.auth.currentUser?.id;
    if (client == null || accountId == null) return;
    try {
      await SignalCrypto(
        client: client,
        accountId: accountId,
        preferences: widget.store.preferences,
      ).ensureLocalKeysPublished();
    } catch (_) {
      // Chat/call flows retry key publication and surface their own errors.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _maybeAutoBackup();
    }
  }

  Future<void> _maybeAutoBackup() async {
    // Web backup not implemented yet
  }

  Future<void> _initializeNotifications() async {
    if (widget.client == null) return;
    await NotifyService.instance.initialize(widget.client!);
  }

  Future<void> _watchNotify() async {
    // Web notification watching not implemented yet
  }

  void _onNotifyTap(Map<String, dynamic> payload) {
    // Handle notification tap
  }

  @override
  void dispose() {
    _directUnread?.removeListener(_onUnreadChanged);
    _directUnread?.dispose();
    _conversationRepo?.removeListener(_onUnreadChanged);
    _conversationRepo?.unsubscribeFromMembership();
    _conversationRepo?.dispose();
    if (BadgeService.isInitialized) BadgeService.instance!.dispose();
    _callWatch?.unsubscribe();
    _notifyWatch?.unsubscribe();
    _broadcastService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 800;
    
    return Scaffold(
      body: wide
          ? Row(
              children: [
                _Sidebar(
                  store: widget.store,
                  profile: widget.profile,
                  push: widget.push,
                  client: widget.client,
                  startupError: widget.startupError,
                  theme: widget.theme,
                  chatPrefs: widget.chatPrefs,
                  selected: selected,
                  query: query,
                  filter: filter,
                  onOpen: open,
                  onTabChange: (tab) => setState(() => activeTab = tab),
                  activeTab: activeTab,
                  lockRevealed: lockRevealed,
                  archivedOpen: archivedOpen,
                  onLockRevealed: (v) => setState(() => lockRevealed = v),
                  onArchivedOpen: (v) => setState(() => archivedOpen = v),
                  onQueryChange: (q) => setState(() => query = q),
                  onFilterChange: (f) => setState(() => filter = f),
                  onToggleLockRevealed: () => setState(() => lockRevealed = !lockRevealed),
                  onToggleArchived: () => setState(() => archivedOpen = !archivedOpen),
                ),
                Expanded(
                  child: selected != null
                      ? ChatPane(
                          store: widget.store,
                          chat: selected!,
                          onBack: () => setState(() => selected = null),
                        )
                      : _EmptyState(
                          profile: widget.profile,
                          client: widget.client,
                          onNewChat: _showNewChatDialog,
                        ),
                ),
              ],
            )
          : IndexedStack(
              index: activeTab,
              children: [
                _ChatsTab(
                  store: widget.store,
                  profile: widget.profile,
                  client: widget.client,
                  startupError: widget.startupError,
                  theme: widget.theme,
                  chatPrefs: widget.chatPrefs,
                  query: query,
                  filter: filter,
                  lockRevealed: lockRevealed,
                  archivedOpen: archivedOpen,
                  onOpen: (chat) => Navigator.push(
                    context,
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
                  onTabChange: (tab) => setState(() => activeTab = tab),
                  activeTab: activeTab,
                  onQueryChange: (q) => setState(() => query = q),
                  onFilterChange: (f) => setState(() => filter = f),
                  onToggleLockRevealed: () => setState(() => lockRevealed = !lockRevealed),
                  onToggleArchived: () => setState(() => archivedOpen = !archivedOpen),
                ),
                _StatusTab(
                  client: widget.client,
                  profile: widget.profile,
                  preferences: widget.store.preferences,
                ),
                _CallsTab(
                  client: widget.client,
                ),
                _SettingsTab(
                  store: widget.store,
                  profile: widget.profile,
                  push: widget.push,
                  client: widget.client,
                  startupError: widget.startupError,
                  theme: widget.theme,
                  chatPrefs: widget.chatPrefs,
                ),
              ],
            ),
    );
  }

  void _showNewChatDialog() {
    // Show new chat dialog
  }
}

// Placeholder classes for web app
class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.store,
    required this.profile,
    required this.push,
    this.client,
    this.startupError,
    this.theme,
    required this.chatPrefs,
    this.selected,
    this.query = '',
    this.filter = 'all',
    this.lockRevealed = false,
    this.archivedOpen = false,
    required this.onOpen,
    required this.onTabChange,
    this.activeTab = 0,
    this.lockRevealed = false,
    this.archivedOpen = false,
    required this.onQueryChange,
    required this.onFilterChange,
    required this.onToggleLockRevealed,
    required this.onToggleArchived,
    this.lockRevealed = false,
    this.archivedOpen = false,
    required this.onTabChange,
    this.activeTab = 0,
    this.lockRevealed = false,
    this.archivedOpen = false,
  });
  
  final ChatStore store;
  final LocalProfile profile;
  final PushService push;
  final SupabaseClient? client;
  final String? startupError;
  final AppThemeController? theme;
  final ChatPreferences chatPrefs;
  final Conversation? selected;
  final String query;
  final String filter;
  final bool lockRevealed;
  final bool archivedOpen;
  final void Function(Conversation, bool) onOpen;
  final void Function(int) onTabChange;
  final int activeTab;
  final bool lockRevealed;
  final bool archivedOpen;
  final void Function(String) onQueryChange;
  final void Function(String) onFilterChange;
  final VoidCallback onToggleLockRevealed;
  final VoidCallback onToggleArchived;

  @override
  Widget build(BuildContext context) => Container(
    width: 360,
    color: Theme.of(context).scaffoldBackgroundColor,
    child: Column(
      children: [
        _SidebarHeader(profile: profile),
        Expanded(
          child: _ConversationList(
            store: store,
            query: query,
            filter: filter,
            onOpen: onOpen,
            selected: selected,
          ),
        ),
        _SidebarFooter(profile: profile, push: push, client: client),
      ],
    );
}

class _SidebarHeader extends StatelessWidget {
  const _SidebarHeader({required this.profile});
  final LocalProfile profile;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    child: Row(
      children: [
        CircleAvatar(
          radius: 24,
          backgroundColor: const Color(0xFFDDE5FF),
          backgroundImage: profile.avatarUrl != null
              ? NetworkImage(profile.avatarUrl!)
              : null,
          child: profile.avatarUrl == null
              ? Text(
                  profile.name.isEmpty ? '?' : profile.name[0].toUpperCase(),
                  style: const TextStyle(
                    fontSize: 24,
                    color: Color(0xFF245CDB),
                    fontWeight: FontWeight.w700,
                  ),
                )
              : null,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                profile.name.isEmpty ? 'Add your name' : profile.name,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                profile.about,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.qr_code_2_outlined),
          onPressed: () {}, // QR code
        ),
      ],
    );
}

class _ConversationList extends StatelessWidget {
  const _ConversationList({
    required this.store,
    this.query = '',
    this.filter = 'all',
    required this.onOpen,
    this.selected,
  });
  
  final ChatStore store;
  final String query;
  final String filter;
  final void Function(Conversation, bool) onOpen;
  final Conversation? selected;

  @override
  Widget build(BuildContext context) {
    final conversations = store.conversations.where((c) {
      if (filter == 'unread' && c.unread == 0) return false;
      if (filter == 'archived' && !c.archived) return false;
      if (filter == 'locked' && !c.locked) return false;
      if (query.isNotEmpty &&
          !c.name.toLowerCase().contains(query.toLowerCase()) &&
          !c.messages.any((m) => m.text.toLowerCase().contains(query.toLowerCase()))) {
        return false;
      }
      return true;
    }).toList();

    return ListView.builder(
      itemCount: conversations.length,
      itemBuilder: (context, index) {
        final chat = conversations[index];
        final isSelected = selected?.id == chat.id;
        return ListTile(
          selected: isSelected,
          selectedTileColor: Theme.of(context).colorScheme.primaryContainer,
          leading: CircleAvatar(
            radius: 24,
            backgroundColor: chat.color != 0 ? Color(chat.color) : const Color(0xFFDDE5FF),
            backgroundImage: null,
            child: Text(
              chat.name.isEmpty ? '?' : chat.name[0].toUpperCase(),
              style: const TextStyle(
                fontSize: 18,
                color: Color(0xFF245CDB),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          title: Text(
            chat.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: chat.unread > 0 ? FontWeight.w700 : FontWeight.normal,
            ),
          ),
          subtitle: chat.messages.isNotEmpty
              ? Text(
                  chat.messages.last.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                )
              : null,
          trailing: chat.unread > 0
              ? Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    chat.unread.toString(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                )
              : null,
          onTap: () => onOpen(chat, MediaQuery.of(context).size.width >= 800),
        );
      },
    );
}

class _SidebarFooter extends StatelessWidget {
  const _SidebarFooter({
    required this.profile,
    required this.push,
    this.client,
  });
  final LocalProfile profile;
  final PushService push;
  final SupabaseClient? client;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: () {}, // New chat
            icon: const Icon(Icons.add),
            label: const Text('New chat'),
          ),
        ),
      ],
    );
}

class _ChatsTab extends StatelessWidget {
  const _ChatsTab({
    required this.store,
    required this.profile,
    this.client,
    this.startupError,
    this.theme,
    required this.chatPrefs,
    this.query = '',
    this.filter = 'all',
    this.lockRevealed = false,
    this.archivedOpen = false,
    required this.onOpen,
    required this.onTabChange,
    this.activeTab = 0,
    required this.onQueryChange,
    required this.onFilterChange,
    required this.onToggleLockRevealed,
    required this.onToggleArchived,
  });
  
  final ChatStore store;
  final LocalProfile profile;
  final SupabaseClient? client;
  final String? startupError;
  final AppThemeController? theme;
  final ChatPreferences chatPrefs;
  final String query;
  final String filter;
  final bool lockRevealed;
  final bool archivedOpen;
  final void Function(Conversation) onOpen;
  final void Function(int) onTabChange;
  final int activeTab;
  final void Function(String) onQueryChange;
  final void Function(String) onFilterChange;
  final VoidCallback onToggleLockRevealed;
  final VoidCallback onToggleArchived;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Chats'),
      actions: [
        IconButton(
          icon: const Icon(Icons.search),
          onPressed: () {}, // Search
        ),
        PopupMenuButton<String>(
          onSelected: (value) {
            switch (value) {
              case 'new_chat':
                break;
              case 'new_group':
                break;
              case 'new_broadcast':
                break;
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'new_chat', child: Text('New chat')),
            const PopupMenuItem(value: 'new_group', child: Text('New group')),
            const PopupMenuItem(value: 'new_broadcast', child: Text('New broadcast')),
          ],
        ),
      ],
    ),
    body: Column(
      children: [
        _SearchAndFilter(
          query: '',
          filter: 'all',
          onQueryChange: (_) {},
          onFilterChange: (_) {},
          onToggleLockRevealed: () {},
          onToggleArchived: () {},
        ),
        Expanded(
          child: _ConversationList(
            store: store,
            query: '',
            filter: 'all',
            onOpen: (chat, _) => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  body: SafeArea(
                    child: ChatPane(
                      store: store,
                      chat: chat,
                      onBack: () => Navigator.pop(context),
                    ),
                  ),
                ),
              ),
            selected: null,
          ),
        ),
      ],
    );
}

class _StatusTab extends StatelessWidget {
  const _StatusTab({
    this.client,
    required this.profile,
    required this.preferences,
  });
  final SupabaseClient? client;
  final LocalProfile profile;
  final SharedPreferences preferences;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Status'),
      actions: [
        IconButton(icon: const Icon(Icons.edit), onPressed: () {}),
        IconButton(icon: const Icon(Icons.camera_alt), onPressed: () {}),
      ],
    ),
    body: Center(
      child: Text('Status updates coming soon'),
    ),
  );
}

class _CallsTab extends StatelessWidget {
  const _CallsTab({this.client});
  final SupabaseClient? client;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Calls')),
    body: Center(child: Text('Call history coming soon')),
  );
}

class _SettingsTab extends StatelessWidget {
  const _SettingsTab({
    required this.store,
    required this.profile,
    required this.push,
    this.client,
    this.startupError,
    this.theme,
    required this.chatPrefs,
  });
  final ChatStore store;
  final LocalProfile profile;
  final PushService push;
  final SupabaseClient? client;
  final String? startupError;
  final AppThemeController? theme;
  final ChatPreferences chatPrefs;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: Center(child: Text('Settings coming soon')),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.profile,
    this.client,
    required this.onNewChat,
  });
  final LocalProfile profile;
  final SupabaseClient? client;
  final VoidCallback onNewChat;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.chat_bubble_outline,
          size: 96,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 24),
        Text(
          'Welcome to OpenChat',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'Start a new conversation or scan a QR code',
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: onNewChat,
          icon: const Icon(Icons.add),
          label: const Text('New chat'),
        ),
      ],
    );
  }
}

class ChatPane extends StatelessWidget {
  const ChatPane({
    super.key,
    required this.store,
    required this.chat,
    required this.onBack,
  });
  
  final ChatStore store;
  final Conversation chat;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: onBack,
      ),
      title: Text(chat.name),
      actions: [
        IconButton(icon: const Icon(Icons.video_call), onPressed: () {}),
        IconButton(icon: const Icon(Icons.call), onPressed: () {}),
        IconButton(icon: const Icon(Icons.more_vert), onPressed: () {}),
      ],
    ),
    body: Column(
      children: [
        Expanded(
          child: ListView.builder(
            reverse: true,
            padding: const EdgeInsets.all(16),
            itemCount: chat.messages.length,
            itemBuilder: (context, index) {
              final msg = chat.messages[chat.messages.length - 1 - index];
              return Align(
                alignment: msg.mine ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.75,
                  ),
                  decoration: BoxDecoration(
                    color: msg.mine
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    msg.text,
                    style: TextStyle(
                      color: msg.mine
                          ? Colors.white
                          : Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        _Composer(
          store: store,
          chat: chat,
        ),
      ],
    );
  }
}

class _Composer extends StatefulWidget {
  const _Composer({required this.store, required this.chat});
  final ChatStore store;
  final Conversation chat;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final controller = TextEditingController();
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    controller.addListener(() => setState(() => _hasText = controller.text.isNotEmpty));
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _send() {
    if (!_hasText) return;
    widget.store.send(widget.chat, controller.text);
    controller.clear();
    setState(() => _hasText = false);
  }

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
    decoration: BoxDecoration(
      color: Theme.of(context).scaffoldBackgroundColor,
      border: Border(
        top: BorderSide(
          color: Theme.of(context).dividerColor,
          width: 0.5,
        ),
      ),
    ),
    child: Row(
      children: [
        IconButton(
          icon: const Icon(Icons.attach_file),
          onPressed: () {},
        ),
        Expanded(
          child: TextField(
            controller: controller,
            decoration: InputDecoration(
              hintText: 'Message',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            ),
            onSubmitted: (_) => _send(),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: Icon(_hasText ? Icons.send : Icons.mic),
          onPressed: _hasText ? _send : () {},
          color: Theme.of(context).colorScheme.primary,
        ),
      ],
    );
  }
}