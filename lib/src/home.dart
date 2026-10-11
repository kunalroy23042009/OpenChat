import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_store.dart';
import 'contacts_repository.dart';
import 'local_profile.dart';
import 'push/push_service.dart';
import 'secure_chat_screen.dart';
import 'settings.dart';
import 'theme/app_theme.dart';
import 'status/status_page.dart';
import 'calling/call_history_page.dart';
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
  bool unreadOnly = false;
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

  Future<void> newChat(bool wide) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _NewChatDialog(),
    );
    if (name == null || !mounted) return;
    final chat = await widget.store.create(name);
    if (mounted) open(chat, wide);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 850;
        final chats = widget.store.conversations
            .where(
              (c) =>
                  c.name.toLowerCase().contains(query.toLowerCase()) &&
                  (!unreadOnly || c.unread > 0),
            )
            .toList();
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
                          colors: [Color(0xFF245CDB), Color(0xFF00C6FF), Color(0xFF9D50BB)],
                        ),
                      ),
                      child: const Icon(Icons.auto_awesome, size: 18, color: Colors.white),
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
                    selected: !unreadOnly,
                    onSelected: (_) => setState(() => unreadOnly = false),
                  ),
                  ChoiceChip(
                    label: const Text('Unread'),
                    selected: unreadOnly,
                    onSelected: (_) => setState(() => unreadOnly = true),
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
                        return Padding(
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
                              title: Text(
                                chat.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
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
                            ),
                          ),
                        );
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
            const Padding(
              padding: EdgeInsets.all(24),
              child: Row(
                children: [
                  Icon(
                    Icons.science_outlined,
                    size: 18,
                    color: Color(0xFF66748A),
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Demo workspace · stored on this device',
                      style: TextStyle(fontSize: 12, color: Color(0xFF66748A)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
        final currentBody = switch (activeTab) {
          1 => const StatusPage(),
          2 => const CallHistoryPage(),
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

class _SecureSectionState extends State<_SecureSection> {
  late Future<List<CloudContact>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<CloudContact>> _load() async {
    final contacts = await SupabaseContactsRepository(widget.client).contacts();
    return contacts.where((c) => c.status == 'accepted').toList();
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
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, letterSpacing: 0.4),
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
        FutureBuilder<List<CloudContact>>(
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
                  style: const TextStyle(fontSize: 12, color: Color(0xFF66748A)),
                ),
              );
            }
            final chats = snapshot.data ?? const <CloudContact>[];
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
                  final contact = chats[i];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      backgroundColor: const Color(0xFFE4EBFF),
                      child: Text(
                        contact.name.isEmpty ? '?' : contact.name[0].toUpperCase(),
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
                    subtitle: Text('@${contact.username} • end-to-end encrypted'),
                    trailing: const Icon(Icons.chevron_right),
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
                        ? (widget.chat.isTyping ? 'Thinking…' : 'AI Assistant (${widget.chat.aiProvider ?? "OpenChat"})')
                        : 'Demo contact',
                    style: TextStyle(
                      color: widget.chat.isTyping ? const Color(0xFF245CDB) : const Color(0xFF66748A),
                      fontSize: 12,
                      fontWeight: widget.chat.isTyping ? FontWeight.w600 : FontWeight.normal,
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
                    IconButton(
              tooltip: 'Voice call',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => CallScreen(
                      session: ActiveCallSession(
                        callId: DateTime.now().millisecondsSinceEpoch.toString(),
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
                        callId: DateTime.now().millisecondsSinceEpoch.toString(),
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
              : '🔒 End-to-end encrypted with Signal Protocol & WhatsApp UI',
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
              final totalCount = messages.length + (widget.chat.isTyping ? 1 : 0);
              return ListView.builder(
                controller: scroll,
                reverse: true,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
                itemCount: totalCount,
                itemBuilder: (context, i) {
                  if (widget.chat.isTyping && i == 0) {
                    return Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.only(left: 12, bottom: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
                              style: TextStyle(fontSize: 13, fontStyle: FontStyle.italic),
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
              icon: const Icon(Icons.emoji_emotions_outlined, color: Colors.grey),
              onPressed: () {},
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
                    hintText: 'Message',
                    counterText: '',
                    border: InputBorder.none,
                    filled: false,
                    contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
                tooltip: 'Send',
                onPressed: send,
                icon: const Icon(Icons.send, color: Colors.white, size: 20),
              ),
            ),
          ],
        ),
      ),     ),
      ),
    ],
  );
}
