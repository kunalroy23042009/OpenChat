import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_store.dart';
import 'auth/password_auth.dart';
import 'auth/password_field.dart';
import 'auth/password_page.dart';
import 'auth/phone_auth_page.dart';
import 'contacts_page.dart';
import 'contacts_repository.dart';
import 'google_sign_in.dart';
import 'local_profile.dart';
import 'profile_page.dart';
import 'push/push_service.dart';
import 'recovery_page.dart';
import 'security/security_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.store,
    required this.profile,
    required this.push,
    this.client,
    this.startupError,
  });
  final ChatStore store;
  final LocalProfile profile;
  final PushService push;
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
        final client = widget.client;
        if (client?.auth.currentUser != null) {
          widget.push.syncAccount(client!);
        }
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
    if (busy) return;
    final validation = credentialsValidation(
      email.text,
      password.text,
      register: register,
    );
    if (validation != null) {
      setState(() => feedback = validation);
      return;
    }
    setState(() {
      busy = true;
      feedback = null;
    });
    try {
      final signedIn = await PasswordAuth(widget.client!)
          .authenticate(email.text, password.text, register: register);
      if (!mounted) return;
      feedback = signedIn
          ? 'Signed in. Open People & profile to set your username and invite contacts.'
          : 'Check your email to confirm your account, then sign in.';
      if (signedIn) password.clear();
    } on AuthException catch (e) {
      feedback = passwordAuthError(e);
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
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.account_circle_outlined),
              title: const Text('My profile'),
              subtitle: const Text(
                'Photo, name, and about — the way contacts see you.',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => ProfilePage(
                    profile: widget.profile,
                    client: widget.client,
                  ),
                ),
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.notifications_outlined),
              title: const Text('Notifications'),
              subtitle: Text(switch (widget.push.state) {
                PushState.ready =>
                  widget.client?.auth.currentUser == null
                      ? 'Ready. Sign in to register this device.'
                      : 'This device is registered for message alerts.',
                PushState.denied => 'Notifications are blocked. Allow them in the system settings.',
                PushState.disabled =>
                  'Off. Push setup or permission is incomplete.',
              }),
              trailing: const Icon(Icons.refresh),
              onTap: () async {
                await widget.push.initialize(widget.client);
                if (mounted) setState(() {});
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.lock_outline),
              title: const Text('Device security'),
              subtitle: const Text(
                'Create a local identity and run Signal encryption checks.',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => _SecurityRoute(client: widget.client),
                ),
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
                            builder: (_) => _AccountContactsRoute(
                              client: widget.client!,
                              store: widget.store,
                              push: widget.push,
                              profile: widget.profile,
                            ),
                          ),
                        ),
                  icon: const Icon(Icons.people_outline),
                  label: const Text('People & profile'),
                ),
                OutlinedButton.icon(
                  onPressed: busy
                      ? null
                      : () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                PasswordPage(client: widget.client!),
                          ),
                        ),
                  icon: const Icon(Icons.password),
                  label: const Text('Set / change Open Chat password'),
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
                TextButton(
                  onPressed: busy
                      ? null
                      : () async {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Delete Open Chat account?'),
                              content: const Text(
                                'This will permanently delete your profile, contacts, and cloud account data. This action cannot be undone.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: const Text('Cancel'),
                                ),
                                FilledButton(
                                  style: FilledButton.styleFrom(
                                    backgroundColor:
                                        Theme.of(ctx).colorScheme.error,
                                  ),
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text('Delete account'),
                                ),
                              ],
                            ),
                          );
                          if (confirmed == true && mounted) {
                            setState(() => busy = true);
                            try {
                              final repo = SupabaseContactsRepository(
                                widget.client!,
                              );
                              await repo.deleteAccount();
                              feedback = 'Account deleted.';
                            } catch (e) {
                              feedback = cloudError(e);
                            } finally {
                              if (mounted) setState(() => busy = false);
                            }
                          }
                        },
                  child: Text(
                    'Delete account',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ] else ...[
                TextField(
                  controller: email,
                  enabled: !busy,
                  autocorrect: false,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(labelText: 'Email'),
                ),
                const SizedBox(height: 12),
                PasswordField(
                  controller: password,
                  enabled: !busy,
                  onSubmitted: (_) => authenticate(false),
                ),
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Use your Open Chat password here. For a Google-only account, choose Continue with Google.',
                    style: TextStyle(fontSize: 12),
                  ),
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
                const SizedBox(height: 8),
                GoogleSignInButton(
                  client: widget.client!,
                  onMessage: (message) {
                    if (mounted) setState(() => feedback = message);
                  },
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: busy
                      ? null
                      : () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => PhoneAuthPage(
                              client: widget.client!,
                            ),
                          ),
                        ),
                  icon: const Icon(Icons.phone_android),
                  label: const Text('Sign in with Phone Number'),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: busy
                        ? null
                        : () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  RecoveryPage(client: widget.client!),
                            ),
                          ),
                    child: const Text('Forgot password?'),
                  ),
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

class _SecurityRoute extends StatelessWidget {
  const _SecurityRoute({this.client});
  final SupabaseClient? client;
  @override
  Widget build(BuildContext context) => StreamBuilder<AuthState>(
    stream: client?.auth.onAuthStateChange,
    builder: (context, _) {
      final id = client?.auth.currentUser?.id;
      return SecurityPage(key: ValueKey(id), accountId: id);
    },
  );
}

/// Discard account-scoped data immediately when the active identity changes.
class _AccountContactsRoute extends StatelessWidget {
  const _AccountContactsRoute({
    required this.client,
    required this.store,
    required this.push,
    required this.profile,
  });
  final SupabaseClient client;
  final ChatStore store;
  final PushService push;
  final LocalProfile profile;
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
        client: client,
        store: store,
        push: push,
        profile: profile,
      );
    },
  );
}
