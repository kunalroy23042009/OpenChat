import 'package:supabase_flutter/supabase_flutter.dart';

class PhoneAuthService {
  PhoneAuthService(this.client);
  final SupabaseClient client;

  Future<void> sendOtp(String phoneNumber) async {
    final formattedPhone = _normalizePhoneNumber(phoneNumber);
    if (!_isValidE164(formattedPhone)) {
      throw const AuthException('Invalid phone number. Use E.164 format (e.g. +14155552671).');
    }
    await client.auth.signInWithOtp(
      phone: formattedPhone,
    );
  }

  Future<bool> verifyOtp(String phoneNumber, String token) async {
    final formattedPhone = _normalizePhoneNumber(phoneNumber);
    final response = await client.auth.verifyOTP(
      phone: formattedPhone,
      token: token.trim(),
      type: OtpType.sms,
    );
    return response.session != null;
  }

  static String _normalizePhoneNumber(String phone) {
    final cleaned = phone.trim().replaceAll(RegExp(r'[^\d+]'), '');
    if (!cleaned.startsWith('+')) {
      return '+$cleaned';
    }
    return cleaned;
  }

  static bool _isValidE164(String phone) {
    return RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(phone);
  }
}
