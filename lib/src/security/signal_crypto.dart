import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
