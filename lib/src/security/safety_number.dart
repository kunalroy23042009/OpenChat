import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Contact verification against Signal identity keys.
///
/// The fingerprint is SHA-256 over the raw identity-key bytes, lowercase hex
/// — the exact algorithm the native bridge reports from `status`, so a Dart
/// computation over a claimed bundle key is directly comparable.
class SafetyNumber {
  /// Fingerprint of a base64 identity key (as carried by `claim_key_bundle`).
  /// Throws [FormatException] on invalid input.
  static String fingerprint(String identityKeyB64) {
    final bytes = base64Decode(identityKeyB64);
    if (bytes.isEmpty) throw const FormatException('Empty identity key');
    return sha256.convert(bytes).toString();
  }

  /// Groups hex for display: `abcdef12 3456...` in chunks of 8.
  static String display(String fingerprintHex) {
    final clean = fingerprintHex.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    final chunks = <String>[];
    for (var i = 0; i < clean.length; i += 8) {
      chunks.add(clean.substring(i, (i + 8).clamp(0, clean.length)));
    }
    return chunks.join(' ');
  }

  static String _trustKey(String accountId, String peerId) =>
      'openchat.trusted_fp.v1.$accountId-$peerId';

  /// Fingerprint the user previously marked verified for this peer, if any.
  static String? trustedFingerprint(
    SharedPreferences prefs,
    String accountId,
    String peerId,
  ) =>
      prefs.getString(_trustKey(accountId, peerId));

  static Future<void> markVerified(
    SharedPreferences prefs,
    String accountId,
    String peerId,
    String fingerprintHex,
  ) =>
      prefs.setString(_trustKey(accountId, peerId), fingerprintHex.toLowerCase());

  static Future<void> clearVerified(
    SharedPreferences prefs,
    String accountId,
    String peerId,
  ) =>
      prefs.remove(_trustKey(accountId, peerId));

  /// True when a stored verification exists and still matches [current].
  /// Null means "never verified" — distinct from a changed (failed) check.
  static bool? verifyStatus(
    SharedPreferences prefs,
    String accountId,
    String peerId,
    String current,
  ) {
    final trusted = trustedFingerprint(prefs, accountId, peerId);
    if (trusted == null) return null;
    return trusted == current.toLowerCase();
  }
}
