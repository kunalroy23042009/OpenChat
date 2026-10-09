import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'password_auth.dart';
import 'password_field.dart';

/// A verified existing session (including Google OAuth or email recovery) is
/// required. This changes only the signed-in account's Supabase password.
class PasswordPage extends StatefulWidget {
  const PasswordPage({super.key, required this.client, this.recovery = false});
  final SupabaseClient client;
  final bool recovery;
  @override
  State<PasswordPage> createState() => _PasswordPageState();
}

class _PasswordPageState extends State<PasswordPage> {
  final password = TextEditingController();
  final confirm = TextEditingController();
  late final String? accountId;
  late final String? accountEmail;
  StreamSubscription<AuthState>? subscription;
  bool busy = false;
  bool saved = false;
  String? feedback;
  bool get sameAccount =>
      accountId != null &&
      widget.client.auth.currentUser?.id == accountId &&
      widget.client.auth.currentSession != null;
  @override
  void initState() {
    super.initState();
    // Capture the account before subscribing; an account switch must not retarget
    // a password form that was opened for somebody else.
    accountId = widget.client.auth.currentUser?.id;
    accountEmail = widget.client.auth.currentUser?.email;
    subscription = widget.client.auth.onAuthStateChange.listen(
      (_) {
        if (mounted) setState(() {});
      },
      onError: (Object _) {
        if (mounted) {
          setState(
            () => feedback = 'Session refresh failed. Check your connection or sign in again.',
          );
        }
      },
    );
  }

  @override
  void dispose() {
    subscription?.cancel();
    password.dispose();
    confirm.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (busy || !sameAccount) return;
    setState(() {
      busy = true;
      feedback = null;
    });
    try {
      await PasswordAuth(widget.client)
          .setPassword(password.text, confirm.text, accountId: accountId!);
      if (!mounted) return;
      password.clear();
      confirm.clear();
      setState(() {
        saved = true;
        feedback =
            'Open Chat password saved for $accountEmail. You can now sign in with that email and this password.';
      });
    } on ArgumentError catch (e) {
      if (mounted) setState(() => feedback = e.message.toString());
    } on AuthException catch (e) {
      if (mounted) setState(() => feedback = passwordAuthError(e));
    } catch (_) {
      if (mounted) {
        setState(
          () => feedback =
              'Could not save your password. Check your connection and retry.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.recovery ? 'Reset Open Chat password' : 'Set Open Chat password',
      ),
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (!sameAccount)
              const Text(
                'Sign in to the intended account before setting its password. Go back to Settings to continue.',
              )
            else ...[
              Text(
                accountEmail ?? 'Your account',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'This is an Open Chat password, separate from your Google password. Only the account shown above will be changed.',
              ),
              const SizedBox(height: 24),
              if (!saved) ...[
                PasswordField(
                  controller: password,
                  label: 'New Open Chat password',
                  newPassword: true,
                  enabled: !busy,
                ),
                const SizedBox(height: 12),
                PasswordField(
                  controller: confirm,
                  label: 'Confirm password',
                  newPassword: true,
                  enabled: !busy,
                  onSubmitted: (_) => save(),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: busy ? null : save,
                  child: Text(busy ? 'Saving…' : 'Save password'),
                ),
              ],
            ],
            if (feedback != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Semantics(liveRegion: true, child: Text(feedback!)),
              ),
            if (saved)
              TextButton(
                onPressed: () => Navigator.maybePop(context),
                child: const Text('Done'),
              ),
          ],
        ),
      ),
    ),
  );
}
