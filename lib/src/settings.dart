import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_store.dart';
import 'contacts_page.dart';
import 'contacts_repository.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.store,
    this.client,
    this.startupError,
  });
  final ChatStore store;
  final SupabaseClient? client;
  final String? startupError;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final email = TextEditingController();
  final password = TextEditingController();
  bool busy = false;
  String? feedback;
  StreamSubscription<AuthState>? authSubscription;
  @override
  void initState() {
    super.initState();
    authSubscription = widget.client?.auth.onAuthStateChange.listen(
      (_) {
        if (mounted) setState(() {});
      },
      onError: (Object _) {
        if (mounted) {
          setState(
            () => feedback = 'Your session could not refresh. Check your connection or sign in again.',
          );
        }
      },
    );
  }

  @override
  void dispose() {
    authSubscription?.cancel();
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> authenticate(bool register) async {
    if (!email.text.contains('@') || password.text.length < 8) {
      setState(
        () => feedback =
            'Enter an email address and a password of at least 8 characters.',
      );
      return;
    }
    setState(() {
      busy = true;
      feedback = null;
    });
    try {
      if (register) {
        final result = await widget.client!.auth.signUp(
          email: email.text.trim(),
          password: password.text,
        );
        feedback = result.session == null
            ? 'Check your email to confirm your account, then sign in.'
            : 'Account created.';
      } else {
        await widget.client!.auth.signInWithPassword(
          email: email.text.trim(),
          password: password.text,
        );
        feedback = 'Signed in. Open People & profile to set your username and invite contacts.';
      }
      if (mounted) password.clear();
    } on AuthException catch (e) {
      feedback = e.message;
    } catch (_) {
      feedback = 'Could not connect. Check your connection and try again.';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings & account')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'Your space.',
              style: TextStyle(fontSize: 32, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            const Text(
              'Connect your real account and contacts below. Chat conversations are still a local demo.',
            ),
            const SizedBox(height: 28),
            const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.science_outlined),
              title: Text('Local demo storage'),
              subtitle: Text(
                'Unencrypted sample data. Use fictional messages only.',
              ),
            ),
            const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.lock_outline),
              title: Text('Encryption: planned'),
              subtitle: Text(
                'Signal sessions and encrypted local storage are phase 3.',
              ),
            ),
            const Divider(height: 40),
            if (widget.startupError != null) Text(widget.startupError!),
            if (widget.client == null) ...[
              const Text(
                'Connect Supabase',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              const Text(
                'Run with SUPABASE_URL and SUPABASE_ANON_KEY using --dart-define-from-file. Setup instructions are in README.md.',
              ),
            ] else ...[
              const Text(
                'Cloud account',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              if (widget.client!.auth.currentUser != null) ...[
                Text('Signed in as ${widget.client!.auth.currentUser!.email}'),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: busy
                      ? null
                      : () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                _AccountContactsRoute(client: widget.client!),
                          ),
                        ),
                  icon: const Icon(Icons.people_outline),
                  label: const Text('People & profile'),
                ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () async {
                          setState(() => busy = true);
                          try {
                            await widget.client!.auth.signOut();
                            feedback = 'Signed out.';
                          } catch (_) {
                            feedback = 'Sign out failed. Try again.';
                          } finally {
                            if (mounted) setState(() => busy = false);
                          }
                        },
                  child: const Text('Sign out'),
                ),
              ] else ...[
                TextField(
                  controller: email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(labelText: 'Email'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: password,
                  obscureText: true,
                  autofillHints: const [AutofillHints.password],
                  decoration: const InputDecoration(labelText: 'Password'),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: busy ? null : () => authenticate(false),
                  child: Text(busy ? 'Please wait…' : 'Sign in'),
                ),
                TextButton(
                  onPressed: busy ? null : () => authenticate(true),
                  child: const Text('Create account'),
                ),
              ],
            ],
            if (feedback != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Semantics(liveRegion: true, child: Text(feedback!)),
              ),
            const Divider(height: 40),
            OutlinedButton.icon(
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Reset demo conversations?'),
                    content: const Text(
                      'This removes your local demo messages and restores the sample conversations.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Reset'),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  await widget.store.reset();
                  if (mounted) {
                    setState(() => feedback = 'Demo conversations restored.');
                  }
                }
              },
              icon: const Icon(Icons.restart_alt),
              label: const Text('Reset demo data'),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Discard account-scoped data immediately when the active identity changes.
class _AccountContactsRoute extends StatelessWidget {
  const _AccountContactsRoute({required this.client});
  final SupabaseClient client;
  @override
  Widget build(BuildContext context) => StreamBuilder<AuthState>(
    stream: client.auth.onAuthStateChange,
    builder: (context, snapshot) {
      final user = client.auth.currentUser;
      if (user == null) {
        return Scaffold(
          appBar: AppBar(title: const Text('Sign in required')),
          body: const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Your session has ended. Go back to settings and sign in.',
              ),
            ),
          ),
        );
      }
      return ContactsPage(
        key: ValueKey(user.id),
        repository: SupabaseContactsRepository(client),
      );
    },
  );
}
