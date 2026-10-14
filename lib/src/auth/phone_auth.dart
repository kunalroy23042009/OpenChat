import 'package:firebase_auth/firebase_auth.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// WhatsApp-style phone login over Firebase OTP.
/// Flow: Firebase sends/verifies the SMS, then the verified Firebase ID
/// token is exchanged server-side (verify-phone edge function) for a
/// single-use Supabase OTP that mints the real session. Supabase SMS
/// provider config is not required.
///
/// Temporarily disabled: Firebase now requires Blaze billing for real SMS
/// delivery (BILLING_NOT_ENABLED). Re-enable after upgrading billing.
const bool kPhoneAuthEnabled = false;

/// Tracks the terminal state of one Firebase phone-verification attempt.
///
/// Firebase delivers the outcome through callbacks that can arrive long
/// after [FirebaseAuth.verifyPhoneNumber] returns (slow reCAPTCHA on
/// emulators, SafetyNet attestation on real devices). Centralizing the
/// state here keeps the "first terminal event wins" rule in one place and
/// makes it unit-testable without Firebase.
class OtpStartState {
  String? verificationId;
  AuthException? startError;
  bool autoCompleted = false;

  /// True once a verification ID is available for manual code entry.
  bool get codeReady => verificationId != null && verificationId!.isNotEmpty;

  /// True once the attempt has reached any terminal state: auto-verified,
  /// code available for manual entry, or a definitive failure.
  bool get settled => autoCompleted || codeReady || startError != null;

  /// Returns true if this call newly made the state ready.
  bool markCodeSent(String id) {
    final fresh = !codeReady;
    verificationId ??= id;
    return fresh;
  }

  void markFailed(AuthException error) {
    startError ??= error;
  }

  void markAutoCompleted() {
    autoCompleted = true;
  }
}

class PhoneAuthService {
  PhoneAuthService(this.client);
  final SupabaseClient client;

  final OtpStartState startState = OtpStartState();

  /// True once a verification ID is available for manual code entry.
  bool get codeReady => startState.codeReady;

  /// Fired when Android auto-retrieves the SMS (no manual code entry).
  /// The bool reports whether the Supabase session was established.
  void Function(bool)? onAutoVerified;

  /// Fired whenever a verification ID arrives, however late (slow
  /// reCAPTCHA flows can deliver codeSent well after sendOtp returns).
  void Function()? onCodeSent;

  /// How long sendOtp waits for the first terminal callback before
  /// returning control. Kept beyond Firebase's 60s auto-retrieval timeout
  /// so the timeout callback itself (which carries a verification ID) is
  /// observed instead of reported as a dead end.
  static const startWait = Duration(seconds: 70);
  static const _pollStep = Duration(milliseconds: 250);

  Future<void> sendOtp(String phoneNumber) async {
    final formattedPhone = _normalizePhoneNumber(phoneNumber);
    if (!_isValidE164(formattedPhone)) {
      throw const AuthException(
        'Invalid phone number. Use E.164 format (e.g. +14155552671).',
      );
    }
    try {
      await FirebaseAuth.instance.verifyPhoneNumber(
        phoneNumber: formattedPhone,
        timeout: const Duration(seconds: 60),
        verificationCompleted: (credential) async {
          startState.markAutoCompleted();
          try {
            final signedIn = await _signInWithCredential(credential);
            onAutoVerified?.call(signedIn);
          } catch (_) {
            onAutoVerified?.call(false);
          }
        },
        // NOTE: throwing here does NOT reach the awaiting caller — Firebase
        // reports start failures through this callback only. Remember it so
        // sendOtp can surface the real cause instead of a false "sent".
        verificationFailed: (e) {
          startState.markFailed(AuthException(_firebaseError(e)));
        },
        codeSent: (verificationId, _) {
          if (startState.markCodeSent(verificationId)) onCodeSent?.call();
        },
        codeAutoRetrievalTimeout: (verificationId) {
          if (startState.markCodeSent(verificationId)) onCodeSent?.call();
        },
      );
    } on FirebaseAuthException catch (e) {
      throw AuthException(_firebaseError(e));
    } catch (_) {
      throw const AuthException(
        'Could not send verification SMS. Check your connection and try again.',
      );
    }
    // Wait for the first terminal callback. The callbacks stay wired after
    // this returns, so a late codeSent still advances the UI via onCodeSent
    // instead of stranding the user.
    final deadline = DateTime.now().add(startWait);
    while (!startState.settled && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(_pollStep);
    }
    final startError = startState.startError;
    if (startError != null) throw startError;
  }

  Future<bool> verifyOtp(String phoneNumber, String token) async {
    final verificationId = startState.verificationId;
    if (verificationId == null || verificationId.isEmpty) {
      throw const AuthException(
        'No verification session yet. Wait for the code to arrive, or tap Resend code.',
      );
    }
    final credential = PhoneAuthProvider.credential(
      verificationId: verificationId,
      smsCode: token.trim(),
    );
    return _signInWithCredential(credential);
  }

  /// Signs into Firebase, exchanges the ID token for a Supabase session.
  Future<bool> _signInWithCredential(PhoneAuthCredential credential) async {
    UserCredential firebaseUser;
    try {
      firebaseUser = await FirebaseAuth.instance.signInWithCredential(
        credential,
      );
    } on FirebaseAuthException catch (e) {
      throw AuthException(_firebaseError(e));
    }
    final idToken = await firebaseUser.user?.getIdToken();
    if (idToken == null || idToken.isEmpty) {
      throw const AuthException('Phone verification failed. Try again.');
    }
    Map<String, dynamic>? data;
    try {
      final response = await client.functions.invoke(
        'verify-phone',
        body: {'idToken': idToken},
      );
      if (response.data is Map) {
        data = Map<String, dynamic>.from(response.data as Map);
      }
    } catch (_) {
      throw const AuthException(
        'Could not reach the login service. Check your connection.',
      );
    }
    final email = data?['email'];
    final otp = data?['otp'];
    if (email is! String || otp is! String || email.isEmpty || otp.isEmpty) {
      throw const AuthException('Phone login failed. Try again.');
    }
    try {
      final session = await client.auth.verifyOTP(
        email: email,
        token: otp,
        type: OtpType.magiclink,
      );
      return session.session != null;
    } on AuthException {
      rethrow;
    } catch (_) {
      throw const AuthException('Phone login failed. Try again.');
    }
  }

  static String _firebaseError(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-phone-number':
        return 'Invalid phone number. Use E.164 format (e.g. +14155552671).';
      case 'too-many-requests':
        return 'Too many attempts. Wait a while and try again.';
      case 'invalid-verification-code':
        return 'Invalid code. Check the SMS and try again.';
      case 'session-expired':
        return 'The code expired. Request a new one.';
      case 'app-not-authorized':
        return 'Phone sign-in is not enabled for this app build yet.';
      case 'network-request-failed':
        return 'Could not reach the verification service. Check your connection.';
      default:
        return 'Phone verification failed. Try again.';
    }
  }

  static String normalizePhoneNumber(String phone) {
    final cleaned = phone.trim().replaceAll(RegExp(r'[^\d+]'), '');
    if (!cleaned.startsWith('+')) {
      return '+$cleaned';
    }
    return cleaned;
  }

  static bool isValidE164(String phone) {
    return RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(phone);
  }

  static String _normalizePhoneNumber(String phone) =>
      normalizePhoneNumber(phone);

  static bool _isValidE164(String phone) => isValidE164(phone);
}
