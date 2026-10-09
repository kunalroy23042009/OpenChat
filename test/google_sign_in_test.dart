import 'package:flutter_test/flutter_test.dart';
import 'package:open_chat/src/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('unconfigured provider maps to setup guidance', () {
    expect(
      googleAuthError(
        const AuthException('Unsupported provider: provider is not enabled'),
      ),
      contains('docs/GOOGLE_SETUP.md'),
    );
  });

  test('other auth errors pass through unchanged', () {
    expect(
      googleAuthError(const AuthException('User already registered')),
      'User already registered',
    );
  });

  test('app auth callback is stable', () {
    expect(authCallbackUrl, 'dev.openchat.openchat://auth-callback');
  });
}
