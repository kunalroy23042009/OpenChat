import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_store.dart';
import 'chat_preferences.dart';
import 'push/notify_service.dart';
import 'media/media_message.dart';
import 'security/envelope_codec.dart';

/// Headless encrypted 1:1 sender shared by broadcast lists (and any future
/// multi-recipient flow). Mirrors SecureChatScreen's transmit path:
/// ensure session -> native encrypt -> enqueue_message -> local store copy.
/// Failures never enqueue; returns per-peer outcomes.
class SecureSendService {
  SecureSendService(this.client, this.store);

  static const _channel = MethodChannel('dev.openchat/security');

  final SupabaseClient client;
  final ChatStore store;

  String get _accountId => client.auth.currentUser?.id ?? '';

  /// Sends [text] to one peer. Returns a per-peer result.
  Future<SecureSendResult> sendText(String peerId, String text) async {
    final accountId = _accountId;
    if (accountId.isEmpty || peerId.isEmpty || peerId == accountId) {
      return SecureSendResult.failed(peerId, 'Cannot send to this contact.');
    }
    if (text.trim().isEmpty || text.length > 4000) {
      return SecureSendResult.failed(peerId, 'Enter a message of up to 4000 characters.');
    }
    var outgoing = encodeTextBody(text);
    final seconds = ChatPreferences(store.preferences).disappearingSecondsFor(peerId);
    if (seconds > 0) {
      outgoing = encodeExpiringBody(outgoing, DateTime.now().toUtc().add(Duration(seconds: seconds)));
    }
    final localId = base64UrlEncode(
      List<int>.generate(24, (_) => Random.secure().nextInt(256)),
    );
    try {
      await _ensureSession(accountId, peerId);
      final result = await _channel.invokeMethod('signalEncrypt', {
        'accountId': accountId,
        'peerId': peerId,
        'plain': base64Encode(utf8.encode(outgoing)),
      }) as Map<dynamic, dynamic>;
      final ciphertext = EnvelopeCodec.encode(
        result['type'] as int,
        result['body'] as String,
      );
      final queued = await client.rpc(
        'enqueue_message',
        params: {
          'p_recipient_id': peerId,
          'p_client_message_id': localId,
          'p_ciphertext': ciphertext,
        },
      ) as Map<String, dynamic>;
      switch (queued['status'] as String?) {
        case 'sent':
        case 'duplicate':
          final at =
              DateTime.tryParse(queued['created_at'] as String? ?? '') ??
              DateTime.now();
          await store.addSecureMessage(
            accountId,
            peerId,
            outgoing,
            mine: true,
            clientId: localId,
            at: at,
          );
          try {
            await NotifyService.poke(client, kind: 'message', peer: peerId);
          } catch (_) {
            // Notification failure must not turn an accepted send into failure.
          }
          return SecureSendResult.sent(peerId);
        case 'rate_limited':
          return SecureSendResult.failed(
            peerId,
            'Daily send limit reached in this chat.',
          );
        case 'unavailable':
          return SecureSendResult.failed(
            peerId,
            'Not delivered — the contact request must be accepted.',
          );
        default:
          return SecureSendResult.failed(peerId, 'Rejected by the server.');
      }
    } catch (e) {
      final message = _friendly(e, peerId);
      return SecureSendResult.failed(peerId, message);
    }
  }

  /// Sends [text] to every peer, sequentially (native session store is not
  /// safe to hammer concurrently). Called per list; surface the outcome map.
  Future<Map<String, SecureSendResult>> broadcast(
    Iterable<String> peerIds,
    String text,
  ) async {
    final results = <String, SecureSendResult>{};
    for (final peer in peerIds) {
      results[peer] = await sendText(peer, text);
    }
    return results;
  }

  Future<void> _ensureSession(String accountId, String peerId) async {
    final sessionState = await _channel.invokeMapMethod('signalHasSession', {
      'accountId': accountId,
      'peerId': peerId,
    });
    final hasSession = sessionState?['hasSession'] == true;
    if (hasSession) return;
    Map<String, dynamic>? claimed;
    try {
      claimed = await client.rpc(
        'claim_key_bundle',
        params: {'p_user_id': peerId},
      ) as Map<String, dynamic>;
    } catch (_) {
      if (hasSession) return;
      rethrow;
    }
    // Reinstall safety mirror of the chat screen: if we remember a
    // different identity key from before, drop the stale session and
    // trust the fresh key so processBundle/encrypt do not fail forever.
    final identity = claimed['identity_key'] as String?;
    final pref = 'openchat.peerIdentity.v1.$accountId.$peerId';
    if (identity != null) {
      await store.preferences.setString(pref, identity);
    }
    try {
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
    } catch (e) {
      if (!e.toString().contains('UntrustedIdentity')) rethrow;
      try {
        await _channel.invokeMethod('signalDeleteSession', {
          'accountId': accountId,
          'peerId': peerId,
          'identityKey': ?identity,
        });
      } catch (_) {}
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
  }

  String _friendly(Object e, String peerId) {
    final text = e.toString();
    if (text.contains('UntrustedIdentity')) {
      return 'Security code changed. Open the chat once, then try again.';
    }
    if (text.contains('refresh one-time keys')) {
      return 'Recipient must open the app once to refresh their keys.';
    }
    if (text.contains('Contact has no published keys yet')) {
      return 'Recipient has not finished registering yet.';
    }
    return 'Could not send (network?). Try again later.';
  }
}

class SecureSendResult {
  SecureSendResult._(this.peerId, this.ok, this.error);
  factory SecureSendResult.sent(String peerId) =>
      SecureSendResult._(peerId, true, null);
  factory SecureSendResult.failed(String peerId, String error) =>
      SecureSendResult._(peerId, false, error);

  final String peerId;
  final bool ok;
  final String? error;
}
