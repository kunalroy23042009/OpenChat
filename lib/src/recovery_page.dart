import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth/password_auth.dart';

/// Sends recovery mail only. The application-level recovery listener opens
/// PasswordPage after Supabase validates the link and emits passwordRecovery.
class RecoveryPage extends StatefulWidget {
  const RecoveryPage({super.key, required this.client});
  final SupabaseClient client;
  @override
  State<RecoveryPage> createState() => _RecoveryPageState();
}

class _RecoveryPageState extends State<RecoveryPage> {
  final email = TextEditingController();
  bool busy = false;
  bool emailSent = false;
  String? feedback;
  @override
  void dispose() {
    email.dispose();
    super.dispose();
  }

  Future<void> sendLink() async {
    if (busy) return;
    final validation = credentialsValidation(
      email.text,
      'unused',
      register: false,
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
      await widget.client.auth.resetPasswordForEmail(
        normalizeEmail(email.text),
        redirectTo: passwordRecoveryRedirect(),
      );
      if (mounted) {
        setState(() {
          emailSent = true;
          feedback = 'Reset requested. If the account is eligible, look for a reset email (including spam). Open its link on this device. The password form opens after the link is verified.';
        });
      }
    } on AuthException catch (e) {
      if (mounted) setState(() => feedback = passwordAuthError(e));
    } catch (_) {
      if (mounted) {
        setState(
          () => feedback =
              'Could not request a reset. Check your connection and retry.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Reset password')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'Recover your account',
              style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            const Text(
              'Request a link to reset your Open Chat password. Keep this app installed and open the email link on this device.',
            ),
            const SizedBox(height: 24),
            TextField(
              controller: email,
              enabled: !busy,
              autocorrect: false,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(labelText: 'Account email'),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: busy ? null : sendLink,
              child: Text(
                busy
                    ? 'Requesting…'
                    : emailSent
                    ? 'Request another link'
                    : 'Send reset link',
              ),
            ),
            if (feedback != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Semantics(liveRegion: true, child: Text(feedback!)),
              ),
            const SizedBox(height: 24),
            const Text(
              'If you can sign in with Google for this exact email, use Settings → Set / change Open Chat password instead. It does not need an email.',
            ),
            const SizedBox(height: 12),
            const Text(
              'No email arriving? Delivery depends on the project’s mail sender. Contact support at itsroydob@gmail.com.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    ),
  );
}
