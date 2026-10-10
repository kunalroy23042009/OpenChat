import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_store.dart';
import 'contacts_repository.dart';
import 'local_profile.dart';
import 'push/push_service.dart';
import 'secure_chat_screen.dart';

class ContactsPage extends StatefulWidget {
  const ContactsPage({
    super.key,
    required this.repository,
    this.client,
    this.store,
    this.push,
    this.profile,
  });
  final ContactsRepository repository;
  final SupabaseClient? client;
  final ChatStore? store;
  final PushService? push;
  final LocalProfile? profile;
  @override
  State<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends State<ContactsPage>
    with WidgetsBindingObserver {
  final name = TextEditingController();
  final username = TextEditingController();
  final about = TextEditingController();
  final inviteName = TextEditingController();
  final invitePhone = TextEditingController();
  final profileForm = GlobalKey<FormState>();
  List<CloudContact> contacts = [];
  bool loading = true;
  bool busy = false;
  bool loaded = false;
  String? error;
  String? feedback;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    name.dispose();
    username.dispose();
    about.dispose();
    inviteName.dispose();
    invitePhone.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !loading && !busy) load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final profile = await widget.repository.profile();
      final rows = await widget.repository.contacts();
      if (!mounted) return;
      setState(() {
        if (!loaded) {
          name.text = profile.name;
          username.text = profile.username ?? '';
          about.text = profile.about ?? '';
        }
        loaded = true;
        contacts = rows;
      });
    } catch (e) {
      if (mounted) setState(() => error = cloudError(e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> perform(Future<String> Function() action) async {
    setState(() {
      busy = true;
      feedback = null;
      error = null;
    });
    try {
      final message = await action();
      if (!mounted) return;
      setState(() => feedback = message);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
      await load();
    } catch (e) {
      if (mounted) setState(() => error = cloudError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  bool get disabled => loading || busy;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('People & profile'),
      actions: [
        IconButton(
          tooltip: 'Refresh contacts',
          onPressed: disabled ? null : load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: RefreshIndicator(
          onRefresh: () async {
            if (!disabled) await load();
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(24),
            children: [
              const Text(
                'Your people.\nOne connection at a time.',
                style: TextStyle(
                  fontSize: 28,
                  height: 1.15,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Profiles and invitations are saved to your Supabase account. Pull down to check for updates.',
              ),
              if (loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: LinearProgressIndicator(),
                ),
              if (error != null) ...[
                const SizedBox(height: 16),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: disabled ? null : load,
                  child: const Text('Retry'),
                ),
              ],
              if (feedback != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Semantics(liveRegion: true, child: Text(feedback!)),
                ),
              if (loaded) ...[
                const SizedBox(height: 24),
                Form(
                  key: profileForm,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Your profile',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: name,
                        enabled: !disabled,
                        maxLength: 60,
                        decoration: const InputDecoration(
                          labelText: 'Display name',
                        ),
                        validator: (v) => v == null || v.trim().isEmpty
                            ? 'Enter your name.'
                            : null,
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: username,
                        enabled: !disabled,
                        maxLength: 24,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: 'Username',
                          prefixText: '@',
                          helperText: '3–24 letters, numbers or underscores. Start with a letter.',
                          helperMaxLines: 2,
                        ),
                        validator: (v) =>
                            RegExp(r'^[a-z][a-z0-9_]{2,23}$')
                                .hasMatch((v ?? '').trim().toLowerCase())
                            ? null
                            : 'Choose a valid username.',
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: about,
                        enabled: !disabled,
                        maxLength: 140,
                        decoration: const InputDecoration(
                          labelText: 'About',
                          counterText: '',
                          helperText: 'Shown to your contacts.',
                        ),
                        validator: (v) =>
                            (v ?? '').trim().isNotEmpty &&
                                (v ?? '').trim().length <= 140
                            ? null
                            : 'Write a short about line (up to 140 characters).',
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: disabled
                            ? null
                            : () {
                                if (profileForm.currentState!.validate()) {
                                  perform(() async {
                                    await widget.repository.saveProfile(
                                      name.text,
                                      username.text,
                                      about.text,
                                    );
                                    return 'Profile saved. Share your username to connect.';
                                  });
                                }
                              },
                        child: const Text('Save profile'),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 48),
                const Text(
                  'Invite someone',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: inviteName,
                  enabled: !disabled,
                  maxLength: 24,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Their exact username',
                    prefixText: '@',
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: disabled
                      ? null
                      : () {
                          if (!RegExp(r'^[a-z][a-z0-9_]{2,23}$')
                              .hasMatch(inviteName.text.trim().toLowerCase())) {
                            setState(
                              () => error = 'Enter a valid username, without the @ symbol.',
                            );
                            return;
                          }
                          perform(() async {
                            final status = await widget.repository.invite(
                              inviteName.text,
                            );
                            if (mounted && status == 'sent') inviteName.clear();
                            return switch (status) {
                              'sent' => 'Invitation sent.',
                              'already_sent' =>
                                'Your invitation is already pending.',
                              'already_connected' =>
                                'You are already connected.',
                              'incoming_pending' => 'They invited you already. Accept their invitation below.',
                              'profile_required' => 'Save your username before sending invitations.',
                              'rate_limited' => 'Daily invitation limit reached. Try again tomorrow (UTC).',
                              _ => 'That person is unavailable for an invitation. Check the username with them.',
                            };
                          });
                        },
                  icon: const Icon(Icons.person_add_alt_1),
                  label: const Text('Send invitation'),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: invitePhone,
                  enabled: !disabled,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Or invite by phone number (WhatsApp-style)',
                    hintText: '+14155552671',
                    prefixIcon: Icon(Icons.phone),
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: disabled
                      ? null
                      : () {
                          if (invitePhone.text.trim().isEmpty) {
                            setState(() => error = 'Enter a valid phone number (e.g. +14155552671).');
                            return;
                          }
                          perform(() async {
                            final message = await widget.repository.inviteByPhone(
                              invitePhone.text,
                            );
                            if (mounted) invitePhone.clear();
                            return message;
                          });
                        },
                  icon: const Icon(Icons.send_to_mobile),
                  label: const Text('Invite by phone number'),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Up to 20 invitation attempts per day. Fast phone contact discovery.',
                  style: TextStyle(fontSize: 12),
                ),
                const Divider(height: 48),
                section(
                  'Invitations received',
                  contacts
                      .where((c) => c.status == 'pending' && c.incoming)
                      .toList(),
                  'No invitations yet.',
                ),
                section(
                  'Your contacts',
                  contacts.where((c) => c.status == 'accepted').toList(),
                  'Your accepted invitations will appear here.',
                ),
                section(
                  'Invitations sent',
                  contacts
                      .where((c) => c.status == 'pending' && !c.incoming)
                      .toList(),
                  'No pending invitations.',
                ),
                section(
                  'Blocked',
                  contacts.where((c) => c.status == 'blocked').toList(),
                  'No blocked contacts.',
                ),
                const SizedBox(height: 16),
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'Secure messaging is the next milestone. Accepted contacts cannot exchange messages until Signal encryption is connected.',
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );

  Widget section(String title, List<CloudContact> rows, String empty) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      if (rows.isEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child: Text(empty, style: const TextStyle(color: Color(0xFF66748A))),
        ),
      ...rows.map(
        (contact) => Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  contact.name,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text('@${contact.username}'),
                if (contact.about != null && contact.about!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      contact.about!,
                      style: const TextStyle(color: Color(0xFF66748A)),
                    ),
                  ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    if (contact.status == 'accepted' &&
                        widget.client != null &&
                        widget.store != null &&
                        widget.push != null &&
                        widget.profile != null) ...[
                      FilledButton.icon(
                        onPressed: disabled
                            ? null
                            : () => Navigator.push(
                                  context,
                                  MaterialPageRoute<void>(
                                    builder: (_) => SecureChatScreen(
                                      profile: widget.profile!,
                                      store: widget.store!,
                                      push: widget.push!,
                                      client: widget.client!,
                                      peerId: contact.userId,
                                      peerName: contact.name,
                                      peerUsername: contact.username,
                                    ),
                                  ),
                                ),
                        icon: const Icon(Icons.lock_outline, size: 18),
                        label: const Text('Encrypted chat'),
                      ),
                    ],
                    if (contact.status == 'pending' && contact.incoming) ...[
                      FilledButton(
                        onPressed: disabled
                            ? null
                            : () => perform(() async {
                                await widget.repository.respond(
                                  contact.requestId!,
                                  true,
                                );
                                return 'Invitation accepted.';
                              }),
                        child: const Text('Accept'),
                      ),
                      TextButton(
                        onPressed: disabled
                            ? null
                            : () => perform(() async {
                                await widget.repository.respond(
                                  contact.requestId!,
                                  false,
                                );
                                return 'Invitation declined.';
                              }),
                        child: const Text('Decline'),
                      ),
                    ] else if (contact.status == 'pending' && !contact.incoming) ...[
                      OutlinedButton(
                        onPressed: disabled
                            ? null
                            : () => perform(() async {
                                await widget.repository.cancelInvite(
                                  contact.requestId!,
                                );
                                return 'Invitation cancelled.';
                              }),
                        child: const Text('Cancel invitation'),
                      ),
                    ],
                    if (contact.status == 'blocked')
                      TextButton(
                        onPressed: disabled
                            ? null
                            : () => perform(() async {
                                await widget.repository.unblock(contact.userId);
                                return 'Contact unblocked. A new invitation is needed to reconnect.';
                              }),
                        child: const Text('Unblock'),
                      )
                    else
                      TextButton(
                        onPressed: disabled
                            ? null
                            : () async {
                                final confirmed = await showDialog<bool>(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    title: Text('Block ${contact.name}?'),
                                    content: const Text(
                                      'This removes your connection and stops new invitations between you.',
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(context, false),
                                        child: const Text('Cancel'),
                                      ),
                                      FilledButton(
                                        onPressed: () =>
                                            Navigator.pop(context, true),
                                        child: const Text('Block'),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirmed == true && mounted) {
                                  perform(() async {
                                    await widget.repository.block(
                                      contact.userId,
                                    );
                                    return 'Contact blocked.';
                                  });
                                }
                              },
                        child: const Text('Block'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      const SizedBox(height: 16),
    ],
  );
}
