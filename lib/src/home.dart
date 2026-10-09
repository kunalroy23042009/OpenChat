import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_store.dart';
import 'local_profile.dart';
import 'settings.dart';

class ChatHome extends StatefulWidget {
  const ChatHome({
    super.key,
    required this.store,
    required this.profile,
    this.client,
    this.startupError,
  });
  final ChatStore store;
  final LocalProfile profile;
  final SupabaseClient? client;
  final String? startupError;
  @override
  State<ChatHome> createState() => _ChatHomeState();
}

class _ChatHomeState extends State<ChatHome> {
  Conversation? selected;
  String query = '';
  bool unreadOnly = false;
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
                  const Icon(
                    Icons.forum_rounded,
                    color: Color(0xFF245CDB),
                    size: 30,
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'open chat',
                      style: TextStyle(
                        fontSize: 27,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -1.2,
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
                          client: widget.client,
                          startupError: widget.startupError,
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
                : list,
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
    child: Text(
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
                  const Text(
                    'Demo contact',
                    style: TextStyle(color: Color(0xFF66748A), fontSize: 12),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Call availability',
              onPressed: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Calling arrives in phase 6'),
                  content: const Text(
                    'Voice and video require a configured media provider and encrypted key exchange. This demo does not place calls.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Got it'),
                    ),
                  ],
                ),
              ),
              icon: const Icon(Icons.videocam_outlined),
            ),
          ],
        ),
      ),
      Container(
        width: double.infinity,
        color: const Color(0xFFEBF0FC),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: const Text(
          'Local demo • messages are not encrypted or delivered to other people.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: Color(0xFF465C85)),
        ),
      ),
      Expanded(
        child: ListenableBuilder(
          listenable: widget.store,
          builder: (context, _) {
            final messages = widget.chat.messages.reversed.toList();
            if (messages.isEmpty) {
              return const Center(
                child: Text('Your conversation starts here. Say hello!'),
              );
            }
            return ListView.builder(
              controller: scroll,
              reverse: true,
              padding: const EdgeInsets.all(24),
              itemCount: messages.length,
              itemBuilder: (context, i) {
                final message = messages[i];
                return Align(
                  alignment: message.mine
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.sizeOf(context).width < 600
                          ? MediaQuery.sizeOf(context).width * .76
                          : 440,
                    ),
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                    decoration: BoxDecoration(
                      color: message.mine
                          ? const Color(0xFF245CDB)
                          : const Color(0xFFE9EDF4),
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(18),
                        topRight: const Radius.circular(18),
                        bottomLeft: Radius.circular(message.mine ? 18 : 4),
                        bottomRight: Radius.circular(message.mine ? 4 : 18),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        SelectableText(
                          message.text,
                          style: TextStyle(
                            color: message.mine
                                ? Colors.white
                                : const Color(0xFF22334E),
                            fontSize: 15,
                            height: 1.45,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${timeLabel(message.at)}${message.mine ? ' · Local' : ''}',
                          style: TextStyle(
                            fontSize: 10,
                            color: message.mine
                                ? Colors.white70
                                : const Color(0xFF66748A),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: composer,
                minLines: 1,
                maxLines: 5,
                maxLength: 4000,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText: 'Write a message…',
                  counterText: '',
                ),
                onSubmitted: (_) => send(),
              ),
            ),
            const SizedBox(width: 10),
            IconButton.filled(
              tooltip: 'Send message',
              onPressed: send,
              padding: const EdgeInsets.all(16),
              icon: const Icon(Icons.arrow_upward_rounded),
            ),
          ],
        ),
      ),
    ],
  );
}
