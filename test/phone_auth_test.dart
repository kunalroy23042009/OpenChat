import 'package:flutter_test/flutter_test.dart';
import 'package:open_chat/src/auth/phone_auth.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('OtpStartState', () {
    test('starts unsettled with no code', () {
      final state = OtpStartState();
      expect(state.settled, isFalse);
      expect(state.codeReady, isFalse);
    });

    test('first codeSent wins and settles', () {
      final state = OtpStartState();
      expect(state.markCodeSent('vid-1'), isTrue);
      expect(state.codeReady, isTrue);
      expect(state.settled, isTrue);
      expect(state.markCodeSent('vid-2'), isFalse);
      expect(state.verificationId, 'vid-1');
    });

    test('failure settles and keeps the first error', () {
      final state = OtpStartState();
      state.markFailed(const AuthException('first'));
      state.markFailed(const AuthException('second'));
      expect(state.settled, isTrue);
      expect(state.codeReady, isFalse);
      expect(state.startError?.message, 'first');
    });

    test('auto-complete settles without a code', () {
      final state = OtpStartState();
      state.markAutoCompleted();
      expect(state.settled, isTrue);
      expect(state.codeReady, isFalse);
    });

    test('late failure after a code does not erase the code', () {
      final state = OtpStartState();
      state.markCodeSent('vid-1');
      state.markFailed(const AuthException('late'));
      expect(state.codeReady, isTrue);
      expect(state.verificationId, 'vid-1');
    });
  });

  test('phone numbers normalize to E.164', () {
    expect(PhoneAuthService.normalizePhoneNumber('+1 415-555-2671'), '+14155552671');
    expect(PhoneAuthService.normalizePhoneNumber('919876543210'), '+919876543210');
    expect(PhoneAuthService.normalizePhoneNumber('  +44 7700 900077 '), '+447700900077');
  });

  test('E.164 validation accepts real numbers and rejects the rest', () {
    expect(PhoneAuthService.isValidE164('+14155552671'), isTrue);
    expect(PhoneAuthService.isValidE164('+919876543210'), isTrue);
    expect(PhoneAuthService.isValidE164('4155552671'), isFalse);
    expect(PhoneAuthService.isValidE164('+012345678'), isFalse);
    expect(PhoneAuthService.isValidE164('+123456'), isFalse);
    expect(PhoneAuthService.isValidE164('+12345678901234567'), isFalse);
    expect(PhoneAuthService.isValidE164(''), isFalse);
  });
}
