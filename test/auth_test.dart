import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_chat/src/auth/password_auth.dart';
import 'package:open_chat/src/auth/password_field.dart';
import 'package:open_chat/src/auth/recovery_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

AuthState authEvent(AuthChangeEvent event) => AuthState(
  event,
  event == AuthChangeEvent.signedOut
      ? null
      : Session.fromJson({
          'access_token': 'token',
          'token_type': 'bearer',
          'expires_in': 3600,
          'refresh_token': 'refresh',
          'user': {'id': 'user-1', 'aud': 'authenticated'},
        }),
);

void main() {
  group('credentials validation', () {
    test('sign-in accepts existing short passwords unchanged', () {
      expect(
        credentialsValidation('Sam@Example.com ', '123456', register: false),
        isNull,
      );
    });

    test('sign-up still requires eight or more characters', () {
      expect(
        credentialsValidation('sam@example.com', '123456', register: true),
        'Choose a password of at least 8 characters.',
      );
    });

    test('blank passwords are rejected before any network call', () {
      expect(
        credentialsValidation('sam@example.com', '', register: false),
        'Enter your Open Chat password.',
      );
    });

    test('malformed emails are rejected with an exact message', () {
      expect(
        credentialsValidation('not-an-email', 'LongEnough123', register: false),
        'Enter a valid email address.',
      );
    });

    test('email is normalized without touching the password', () {
      expect(normalizeEmail('  SAM@Example.COM\n'), 'sam@example.com');
    });
  });

  group('password auth errors', () {
    test('wrong credentials point at Google-password confusion', () {
      expect(
        passwordAuthError(
          const AuthException(
            'Invalid login credentials',
            code: 'invalid_credentials',
          ),
        ),
        contains('Google password is different'),
      );
    });

    test('rate limits ask for patience, not retries', () {
      expect(
        passwordAuthError(
          const AuthException('slow down', code: 'over_request_rate_limit'),
        ),
        contains('Wait a little'),
      );
    });

    test('unknown errors keep the server message', () {
      expect(
        passwordAuthError(
          const AuthException('Database error saving new user'),
        ),
        'Database error saving new user',
      );
    });
  });

  group('recovery controller', () {
    test(
      'records a verified recovery session and clears on sign-out',
      () async {
        final events = StreamController<AuthState>.broadcast();
        addTearDown(events.close);
        final controller = RecoveryController(events.stream);
        addTearDown(controller.dispose);

        events.add(authEvent(AuthChangeEvent.passwordRecovery));
        await Future<void>.delayed(Duration.zero);
        expect(controller.accountId, 'user-1');

        controller.consume();
        expect(controller.accountId, isNull);

        events.add(authEvent(AuthChangeEvent.signedIn));
        await Future<void>.delayed(Duration.zero);
        expect(controller.accountId, isNull);

        events.add(authEvent(AuthChangeEvent.signedOut));
        await Future<void>.delayed(Duration.zero);
        expect(controller.accountId, isNull);
      },
    );

    test('a recovery event without a session is ignored', () async {
      final events = StreamController<AuthState>.broadcast();
      addTearDown(events.close);
      final controller = RecoveryController(events.stream);
      addTearDown(controller.dispose);

      events.add(const AuthState(AuthChangeEvent.passwordRecovery, null));
      await Future<void>.delayed(Duration.zero);
      expect(controller.accountId, isNull);
    });
  });

  testWidgets('password field reveals text only through its own toggle', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'Secret123');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PasswordField(controller: controller)),
      ),
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).obscureText,
      isTrue,
    );
    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).obscureText,
      isFalse,
    );
    expect(controller.text, 'Secret123');
  });
}
