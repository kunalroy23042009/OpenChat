import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_chat/src/security/safety_number.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('fingerprint is sha256 hex of the raw identity bytes', () {
    final key = base64Encode(List.filled(33, 7));
    final expected = sha256.convert(base64Decode(key)).toString();
    expect(SafetyNumber.fingerprint(key), expected);
    expect(SafetyNumber.fingerprint(key), hasLength(64));
  });

  test('fingerprint rejects invalid input', () {
    expect(() => SafetyNumber.fingerprint('!!!'), throwsFormatException);
    expect(() => SafetyNumber.fingerprint(''), throwsFormatException);
  });

  test('display groups hex in chunks of eight', () {
    const hex = 'abcdef1234567890abcdef1234567890';
    expect(SafetyNumber.display(hex), 'abcdef12 34567890 abcdef12 34567890');
  });

  test('verify status distinguishes never, match, and changed', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    expect(
      SafetyNumber.verifyStatus(prefs, 'a', 'b', '00' * 32),
      isNull,
    );
    await SafetyNumber.markVerified(prefs, 'a', 'b', 'AB' * 32);
    expect(
      SafetyNumber.verifyStatus(prefs, 'a', 'b', 'ab' * 32),
      isTrue,
    );
    expect(
      SafetyNumber.verifyStatus(prefs, 'a', 'b', 'ff' * 32),
      isFalse,
    );
    await SafetyNumber.clearVerified(prefs, 'a', 'b');
    expect(
      SafetyNumber.verifyStatus(prefs, 'a', 'b', 'ab' * 32),
      isNull,
    );
  });
}
