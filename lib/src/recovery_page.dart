import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Password recovery: send a reset email, then set a new password after
/// opening the link on this device. The link returns through the
/// dev.openchat.openchat://auth-callback deep link declared for Android/iOS.
class RecoveryPage extends StatefulWidget {
  const RecoveryPage({super.key, required this.client});
  final SupabaseClient client;

  @override
  State<RecoveryPage> createState() => _RecoveryPageState();
}

class _RecoveryPageState extends State<RecoveryPage> {
  final email = TextEditingController();
  final password = TextEditingController();
  final confirm = TextEditingController();
  StreamSubscription<AuthState>? authSubscription;
  bool busy = false;
  bool emailSent = false;
  String? feedback;

  @override
  void initState() {
    super.initState();
    authSubscription = widget.client.auth.onAuthStateChange.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    authSubscription?.cancel();
    email.dispose();
    password.dispose();
    confirm.dispose();
    super.dispose();
  }

  Future<void> sendLink() async {
    if (!email.text.contains('@')) {
      setState(() => feedback = 'Enter the email address of your account.');
      return;
    }
    setState(() {
      busy = true;
      feedback = null;
    });
    try {
      await widget.client.auth.resetPasswordForEmail(
        email.text.trim(),
        redirectTo: 'dev.openchat.openchat://auth-callback',
      );
      if (mounted) {
        setState(() {
          emailSent = true;
          feedback = 'Reset link sent. Open it on this device, then set a new password below.';
        });
      }
    } on AuthException catch (e) {
      if (mounted) setState(() => feedback = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => feedback = 'Could not send the reset email. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> setPassword() async {
    if (password.text.length < 8) {
      setState(() => feedback = 'Use a password of at least 8 characters.');
      return;
    }
    if (password.text != confirm.text) {
      setState(() => feedback = 'The new passwords do not match.');
      return;
    }
    setState(() {
      busy = true;
      feedback = null;
    });
    try {
      await widget.client.auth.updateUser(
        UserAttributes(password: password.text),
      );
      if (mounted) {
        setState(() => feedback = 'Password updated. You are signed in.');
        password.clear();
        confirm.clear();
      }
    } on AuthException catch (e) {
      if (mounted) setState(() => feedback = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => feedback = 'Could not update the password. Open the reset link first, then retry.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = widget.client.auth.currentUser != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Reset password')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            padding: const EdgeInsets.all(32),
            children: [
              const Text(
                'Locked out?',
                style: TextStyle(fontSize: 32, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              const Text(
                'We will email you a link. Open it on this device to choose a new password.',
                style: TextStyle(color: Color(0xFF66748A)),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: email,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(labelText: 'Account email'),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: busy ? null : sendLink,
                child: Text(
                  busy && !emailSent ? 'Please wait…' : 'Send reset link',
                ),
              ),
              if (emailSent) ...[
                const Divider(height: 48),
                const Text(
                  'Choose a new password',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  signedIn ? 'Reset link accepted — enter your new password.' : 'Waiting for the reset link. Open it on this device, then return here.',
                  style: const TextStyle(color: Color(0xFF66748A)),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: password,
                  obscureText: true,
                  autofillHints: const [AutofillHints.newPassword],
                  decoration: const InputDecoration(labelText: 'New password'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: confirm,
                  obscureText: true,
                  autofillHints: const [AutofillHints.newPassword],
                  decoration: const InputDecoration(
                    labelText: 'Confirm new password',
                  ),
                  onSubmitted: (_) => setPassword(),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: busy ? null : setPassword,
                  child: Text(busy ? 'Please wait…' : 'Set new password'),
                ),
              ],
              if (feedback != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Semantics(liveRegion: true, child: Text(feedback!)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
