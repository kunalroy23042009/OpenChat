import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// App deep link that receives Supabase auth callbacks (OAuth, recovery).
/// It must stay allow-listed in the Supabase Auth redirect settings.
const authCallbackUrl = 'dev.openchat.openchat://auth-callback';

String googleAuthError(AuthException error) {
  if (error.message.contains('not enabled') ||
      error.message.contains('Unsupported provider')) {
    return 'Google sign-in is not switched on for this project yet. '
        'Finish the Google Cloud setup in docs/GOOGLE_SETUP.md, then retry.';
  }
  return error.message;
}

/// "Continue with Google" button. On success the session arrives through
/// the auth deep link, so parents must react to auth-state changes.
class GoogleSignInButton extends StatefulWidget {
  const GoogleSignInButton({
    super.key,
    required this.client,
    this.onMessage,
    this.onLaunched,
  });
  final SupabaseClient client;
  final ValueChanged<String>? onMessage;
  final VoidCallback? onLaunched;

  @override
  State<GoogleSignInButton> createState() => _GoogleSignInButtonState();
}

class _GoogleSignInButtonState extends State<GoogleSignInButton> {
  bool busy = false;

  Future<void> run() async {
    setState(() => busy = true);
    try {
      final launched = await widget.client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: authCallbackUrl,
        authScreenLaunchMode: LaunchMode.externalApplication,
      );
      if (!mounted) return;
      if (launched) {
        widget.onLaunched?.call();
        widget.onMessage?.call(
          'Continue with Google in the browser, then return here.',
        );
      } else {
        widget.onMessage?.call('Could not open Google sign-in. Try again.');
      }
    } on AuthException catch (e) {
      if (mounted) widget.onMessage?.call(googleAuthError(e));
    } catch (_) {
      if (mounted) {
        widget.onMessage?.call(
          'Google sign-in failed. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: busy ? null : run,
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(double.infinity, 52),
    ),
    icon: busy
        ? const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.g_mobiledata_rounded, size: 28),
    label: const Text('Continue with Google'),
  );
}
