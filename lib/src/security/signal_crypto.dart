import 'dart:convert';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../ops/error_report.dart';
import 'envelope_codec.dart';

/// Minimal Signal Protocol operations shared by call-key exchange and secure
/// chat. Private identities and ratchet state remain in the Android native
/// layer; Dart sees only public bundles and encrypted message packets.
class SignalCrypto {
  SignalCrypto({
    required this.client,
    required this.accountId,
    required this.preferences,
  });

  static const _channel = MethodChannel('dev.openchat/security');
  static String _publishedKey(String uid) => 'openchat.keysPublished.v1.$uid';
  static String _identityKey(String uid, String peer) =>
      'openchat.peerIdentity.v1.$uid.$peer';
  static const _poolCheckKey = 'openchat.prekeyPoolCheckAt.v1';

  /// Minimum one-time keys before a top-up run is worth it. Senders fail
  /// with "Contact must reopen the app to refresh one-time keys" once a
  /// peer's pool drains, because publish_key_bundle runs only at install.
  static const _minEcPrekeys = 10;
  static const _minKyberPrekeys = 3;

  /// How often the locally-owned prekey pool is inspected. The check is
  /// one RPC; the top-up itself runs only when the pool is too low.
  static const _poolCheckInterval = Duration(hours: 6);

  final SupabaseClient client;
  final String accountId;
  final SharedPreferences preferences;

  Future<void> ensureLocalKeysPublished() async {
    final initialized = await _channel.invokeMapMethod<String, dynamic>(
      'initialize',
      {'accountId': accountId},
    );
    await _channel.invokeMapMethod<String, dynamic>('status', {
      'accountId': accountId,
    });
    if (preferences.getBool(_publishedKey(accountId)) == true &&
        initialized?['fresh'] != true) {
      // Identity already published: keep the one-time-key pool topped up
      // instead. Sending contacts consume these; an empty pool breaks
      // incoming messages on every installed app (nothing re-published
      // them before).
      unawaited(_maybeTopUpPrekeys());
      return;
    }
    final bundle = await _channel.invokeMapMethod<String, dynamic>(
      'signalPublish',
      {'accountId': accountId},
    );
    if (bundle == null) {
      throw StateError('Signal identity initialization failed.');
    }
    await client.rpc(
      'publish_key_bundle',
      params: {
        'p_identity_key': bundle['identityKey'],
        'p_registration_id': bundle['registrationId'],
        'p_signed_prekey_id': bundle['signedPrekeyId'],
        'p_signed_prekey': bundle['signedPrekey'],
        'p_signed_prekey_signature': bundle['signedPrekeySignature'],
        'p_prekeys': _json(bundle['prekeys']),
        'p_kyber': _json(bundle['kyber']),
      },
    );
    await preferences.setBool(_publishedKey(accountId), true);
  }

  /// Checks the one-time-prekey pool at most once per interval and tops it
  /// up when low. Identity and ratchet sessions are untouched: freshBundle
  /// reuses the stored identity, and publish_key_bundle only replaces
  /// unclaimed prekey rows, so sessions peers already hold stay valid.
  Future<void> _maybeTopUpPrekeys() async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final last = preferences.getInt(_poolCheckKey) ?? 0;
    if (nowMs - last < _poolCheckInterval.inMilliseconds) return;
    await preferences.setInt(_poolCheckKey, nowMs);
    try {
      final counts =
          await client.rpc('prekey_pool_counts') as Map<String, dynamic>;
      final ec = (counts['ec_available'] as num?)?.toInt() ?? 0;
      final kyber = (counts['kyber_available'] as num?)?.toInt() ?? 0;
      if (ec < _minEcPrekeys || kyber < _minKyberPrekeys) {
        ErrorReport.report(
          area: 'prekeys-topup',
          code: 'pool_low',
          details: {'ec': '$ec', 'kyber': '$kyber'},
        );
        await refreshPrekeysNow(report: 'pool_low');
      }
    } catch (_) {
      // Older backend without the pool RPC: harmless, retried later.
    }
  }

  /// Publishes a fresh prekey pool on demand (app resume, low-pool report).
  /// Never throws to the caller: a top-up failure only delays refresh.
  Future<void> refreshPrekeysNow({String report = 'manual'}) async {
    try {
      final bundle = await _channel.invokeMapMethod<String, dynamic>(
        'signalPublish',
        {'accountId': accountId},
      );
      if (bundle == null) return;
      await client.rpc(
        'top_up_prekeys',
        params: {
          'p_prekeys': _json(bundle['prekeys']),
          'p_kyber': _json(bundle['kyber']),
        },
      );
      ErrorReport.report(
        area: 'prekeys-topup',
        code: report,
        details: const {'result': 'published'},
      );
    } catch (e) {
      ErrorReport.report(area: 'prekeys-topup', error: e);
    }
  }

  Future<void> _ensureSession(String peerId) async {
    await ensureLocalKeysPublished();
    final existing = await _channel.invokeMapMethod<String, dynamic>(
      'signalHasSession',
      {'accountId': accountId, 'peerId': peerId},
    );
    final hasSession = existing?['hasSession'] == true;
    final claimed = await client.rpc(
      'claim_key_bundle',
      params: {'p_user_id': peerId},
    ) as Map<String, dynamic>;
    final identity = claimed['identity_key'] as String?;
    final trustKey = _identityKey(accountId, peerId);
    final known = preferences.getString(trustKey);
    if (hasSession && known == identity) return;
    if (hasSession || (known != null && known != identity)) {
      await _channel.invokeMethod('signalDeleteSession', {
        'accountId': accountId,
        'peerId': peerId,
        'identityKey': identity,
      });
    }
    if (identity != null) {
      await preferences.setString(trustKey, identity);
    }
    await _channel.invokeMethod('signalProcessBundle', {
      'accountId': accountId,
      'peerId': peerId,
      'bundle': {
        'registrationId': claimed['registration_id'],
        'identityKey': claimed['identity_key'],
        'signedPrekeyId': claimed['signed_prekey_id'],
        'signedPrekey': claimed['signed_prekey'],
        'signedPrekeySignature': claimed['signed_prekey_signature'],
        'prekeyId': claimed['prekey_id'],
        'prekey': claimed['prekey'],
        'kyberId': claimed['kyber_id'],
        'kyber': claimed['kyber'],
        'kyberSignature': claimed['kyber_signature'],
      },
    });
  }

  Future<String> encryptText(String peerId, String clearText) async {
    try {
      return await _encryptOnce(peerId, clearText);
    } catch (error) {
      // Stale or corrupt session state (common after app updates or device
      // restores): reset the peer session, rebuild it from their current
      // key bundle, and retry once.
      await resetPeerSession(peerId, reason: error.toString());
      return await _encryptOnce(peerId, clearText);
    }
  }

  Future<String> _encryptOnce(String peerId, String clearText) async {
    await _ensureSession(peerId);
    final encrypted = await _channel.invokeMapMethod<String, dynamic>(
      'signalEncrypt',
      {
        'accountId': accountId,
        'peerId': peerId,
        'plain': base64Encode(utf8.encode(clearText)),
      },
    );
    if (encrypted == null) throw StateError('Could not encrypt call key.');
    return EnvelopeCodec.encode(
      encrypted['type'] as int,
      encrypted['body'] as String,
    );
  }

  /// Drops the stored session for [peerId] so the next encrypt/decrypt
  /// rebuilds it from the peer's current key bundle. Best effort: when the
  /// reset itself fails the existing session simply stays in place.
  Future<void> resetPeerSession(String peerId, {String? reason}) async {
    try {
      await _channel.invokeMethod('signalDeleteSession', {
        'accountId': accountId,
        'peerId': peerId,
      });
    } catch (error) {
      ErrorReport.report(
        area: 'session-reset',
        code: 'delete_failed',
        details: {'reason': reason ?? ''},
      );
    }
  }

  Future<String> decryptText(String peerId, String packet) async {
    await _ensureSession(peerId);
    Object? lastError;
    for (final candidate in EnvelopeCodec.candidates(packet)) {
      try {
        final result = await _channel.invokeMapMethod<String, dynamic>(
          'signalDecrypt',
          {
            'accountId': accountId,
            'peerId': peerId,
            'type': candidate.key,
            'body': candidate.value,
          },
        );
        final plain = result?['plain'] as String?;
        if (plain == null) throw StateError('Invalid encrypted call key.');
        return utf8.decode(base64Decode(plain));
      } catch (error) {
        lastError = error;
      }
    }
    throw StateError('Could not decrypt the call key. ${lastError ?? ''}');
  }

  static dynamic _json(dynamic value) {
    if (value is Map) {
      return {
        for (final entry in value.entries)
          entry.key.toString(): _json(entry.value),
      };
    }
    if (value is List) return value.map(_json).toList();
    return value;
  }
}
