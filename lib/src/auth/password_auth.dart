import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String normalizeEmail(String email) => email.trim().toLowerCase();

String? credentialsValidation(
  String email,
  String password, {
  required bool register,
}) {
  if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(normalizeEmail(email))) {
    return 'Enter a valid email address.';
  }
  // Existing passwords must reach the server unchanged, regardless of a newer
  // client-side sign-up policy. Do not trim or otherwise transform passwords.
  if (password.isEmpty) return 'Enter your Open Chat password.';
  if (register && password.length < 8) {
    return 'Choose a password of at least 8 characters.';
  }
  return null;
}

String passwordAuthError(AuthException error) {
  switch (error.code) {
    case 'invalid_credentials':
      return 'Email or Open Chat password was not accepted. Your Google password is different. '
          'Use Forgot password, or sign in with Google for the same email and set an Open Chat password in Settings.';
    case 'email_not_confirmed':
      return 'Confirm your email before signing in.';
    case 'over_email_send_rate_limit':
    case 'over_request_rate_limit':
      return 'Too many attempts. Wait a little before trying again.';
    case 'same_password':
      return 'Choose a different password from your current one.';
    case 'reauthentication_needed':
      return 'Sign in again before changing your password.';
    case 'email_address_not_authorized':
      return 'The project’s email sender cannot deliver to this address yet. Contact support to configure email delivery.';
    default:
      return error.message;
  }
}

/// Web callbacks return to this app's origin; native callbacks use the scheme.
String passwordRecoveryRedirect() => kIsWeb
    ? Uri.base.replace(query: '', fragment: '').toString()
    : 'dev.openchat.openchat://auth-callback';

class PasswordAuth {
  PasswordAuth(this.client);
  final SupabaseClient client;

  /// True means a session was obtained; false means confirmation is required.
  Future<bool> authenticate(
    String email,
    String password, {
    required bool register,
  }) async {
    final validation = credentialsValidation(
      email,
      password,
      register: register,
    );
    if (validation != null) throw ArgumentError(validation);
    final normalized = normalizeEmail(email);
    if (register) {
      final result = await client.auth.signUp(
        email: normalized,
        password: password,
      );
      if (result.session != null) return true;
      // A null signup session must not be treated as authenticated.
      return false;
    }
    final result = await client.auth.signInWithPassword(
      email: normalized,
      password: password,
    );
    return result.session != null;
  }

  Future<void> setPassword(
    String password,
    String confirmation, {
    required String accountId,
  }) async {
    if (password.length < 8) {
      throw ArgumentError(
        'Use at least 8 characters for your new Open Chat password.',
      );
    }
    if (password != confirmation) {
      throw ArgumentError('The passwords do not match.');
    }
    if (client.auth.currentSession == null ||
        client.auth.currentUser?.id != accountId) {
      throw const AuthException(
        'Your signed-in account changed. Go back and sign in to the intended account.',
      );
    }
    await client.auth.updateUser(UserAttributes(password: password));
  }
}
