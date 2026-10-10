import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_store.dart';
import 'local_profile.dart';
import 'push/push_service.dart';
import 'security/envelope_codec.dart';
import 'security/safety_number.dart';

class SecureChatScreen extends StatefulWidget {
  const SecureChatScreen({
    super.key,
    required this.profile,
    required this.store,
    required this.push,
    required this.client,
    required this.peerId,
    required this.peerName,
    required this.peerUsername,
  });
  final LocalProfile profile;
  final ChatStore store;
  final PushService push;
  final SupabaseClient client;
  final String peerId;
  final String peerName;
  final String peerUsername;

  @override
  State<SecureChatScreen> createState() => _SecureChatScreenState();
}

class _SecureChatScreenState extends State<SecureChatScreen> {
  final composer = TextEditingController();
  final scroll = ScrollController();
  final channel = const MethodChannel('dev.openchat/security');
  final accountId = Supabase.instance.client.auth.currentUser!.id;

  StreamSubscription? _inboxPoll;
  Timer? _pollTimer;
  bool _loading = true;
  String? _error;
  String? _ownFingerprint;
  String? _peerIdentityKey;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      await channel.invokeMapMethod('initialize', {'accountId': accountId});
      final status = await channel.invokeMapMethod<String, dynamic>(
        'status',
        {'accountId': accountId},
      );
      _ownFingerprint = status?['fingerprint'] as String?;
      await _publishKeys();
      await _ensureSession();
      await widget.store.loadSecureConversation(accountId, widget.peerId);
      _subscribeRealtime();
      _startPolling();
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  /// Publishes this device's key bundle once per account. Republishing
  /// replaces unclaimed one-time keys server-side, so this is gated behind
  /// a local flag and only forced from the manual refresh action.
  Future<void> _publishKeys({bool force = false}) async {
    final flag = 'openchat.keysPublished.v1.$accountId';
    if (!force && widget.store.preferences.getBool(flag) == true) {
      return;
    }
    final result = await channel.invokeMapMethod<String, dynamic>(
      'signalPublish',
      {'accountId': accountId},
    );
    if (result == null) throw StateError('Key publication failed.');
    await widget.client.rpc(
      'publish_key_bundle',
      params: {
        'p_identity_key': result['identityKey'],
        'p_registration_id': result['registrationId'],
        'p_signed_prekey_id': result['signedPrekeyId'],
        'p_signed_prekey': result['signedPrekey'],
        'p_signed_prekey_signature': result['signedPrekeySignature'],
        'p_prekeys': _toJson(result['prekeys']),
        'p_kyber': _toJson(result['kyber']),
      },
    );
    await widget.store.preferences.setBool(flag, true);
  }

  /// Converts platform-channel maps (dynamic keys) into JSON-encodable maps.
  dynamic _toJson(dynamic value) {
    if (value is Map) {
      return {
        for (final entry in value.entries)
          entry.key.toString(): _toJson(entry.value),
      };
    }
    if (value is List) return value.map(_toJson).toList();
    return value;
  }

  Future<void> _ensureSession() async {
    // Native returns {'hasSession': bool}, not a bare bool.
    final sessionState =
        await channel.invokeMapMethod('signalHasSession', {
          'accountId': accountId,
          'peerId': widget.peerId,
        });
    if (sessionState?['hasSession'] == true) return;
    // Server uses snake_case; the native bridge expects camelCase.
    final claimed =
        await widget.client.rpc(
              'claim_key_bundle',
              params: {'p_user_id': widget.peerId},
            )
            as Map<String, dynamic>;
    _peerIdentityKey = claimed['identity_key'] as String?;
    if (mounted) setState(() {});
    await channel.invokeMethod('signalProcessBundle', {
      'accountId': accountId,
      'peerId': widget.peerId,
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

  void _subscribeRealtime() {
    widget.client.channel('envelopes:$accountId')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'message_envelopes',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'recipient_id',
          value: accountId,
        ),
        callback: (payload) => _onEnvelope(payload.newRecord),
      )
      ..subscribe();
  }

  Future<void> _onEnvelope(Map<String, dynamic> record) async {
    final sender = record['sender_id'] as String? ?? widget.peerId;
    final raw = record['ciphertext'] as String? ?? '';
    final candidates = EnvelopeCodec.candidates(raw);
    String? plainText;
    for (final candidate in candidates) {
      try {
        final decrypted =
            await channel.invokeMethod('signalDecrypt', {
              'accountId': accountId,
              'peerId': sender,
              'type': candidate.key,
              'body': candidate.value,
            })
                as Map<dynamic, dynamic>;
        plainText = utf8.decode(
          base64Decode(decrypted['plain'] as String),
        );
        break;
      } catch (_) {}
    }
    try {
      if (plainText != null) {
        await widget.store.addSecureMessage(
          accountId,
          sender,
          plainText,
          mine: false,
        );
        if (mounted) setState(() {});
      }
      // Always acknowledge: undecryptable rows are dropped to avoid a
      // poison envelope being retried on every poll forever.
      await widget.client.rpc(
        'ack_messages',
        params: {
          'p_ids': [record['id']],
        },
      );
    } catch (_) {}
  }

  void _startPolling() {
    _pollTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _pollInbox(),
    );
  }

  Future<void> _pollInbox() async {
    try {
      final since = widget.store
          .lastSecureMessageTime(accountId, widget.peerId)
          ?.toIso8601String();
      final result = await widget.client.rpc(
        'fetch_inbox',
        params: {'p_since': since, 'p_limit': 50},
      ) as List<dynamic>;
      for (final record in result.cast<Map<String, dynamic>>()) {
        await _onEnvelope(record);
      }
    } catch (_) {}
  }

  Future<void> _send() async {
    final text = composer.text.trim();
    if (text.isEmpty || text.length > 4000) return;
    composer.clear();
    try {
      final localId =
          '${DateTime.now().microsecondsSinceEpoch}-${DateTime.now().millisecond}';
      final result = await channel.invokeMethod('signalEncrypt', {
        'accountId': accountId,
        'peerId': widget.peerId,
        'plain': base64Encode(utf8.encode(text)),
      }) as Map<dynamic, dynamic>;
      // Prefix the Signal message type; the envelope has no type column.
      final queued =
          await widget.client.rpc(
                'enqueue_message',
                params: {
                  'p_recipient_id': widget.peerId,
                  'p_client_message_id': localId,
                  'p_ciphertext': EnvelopeCodec.encode(
                    result['type'] as int,
                    result['body'] as String,
                  ),
                },
              )
              as Map<String, dynamic>;
      switch (queued['status']) {
        case 'sent':
        case 'duplicate':
          await widget.store.addSecureMessage(
            accountId,
            widget.peerId,
            text,
            mine: true,
          );
          setState(() {});
        case 'rate_limited':
          throw StateError('Daily send limit reached. Try again tomorrow.');
        case 'unavailable':
          throw StateError('Contact unavailable. They may have blocked you or removed the connection.');
        default:
          throw StateError('Message rejected by the server.');
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Send failed: $e');
    }
  }

  Future<void> _showVerification(BuildContext context) async {
    String? peerPrint;
    try {
      final key = _peerIdentityKey;
      if (key != null) peerPrint = SafetyNumber.fingerprint(key);
    } catch (_) {}
    final trusted = peerPrint == null
        ? null
        : SafetyNumber.verifyStatus(
            widget.store.preferences,
            accountId,
            widget.peerId,
            peerPrint,
          );
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Verify ${widget.peerName}',
              style: Theme.of(sheetContext).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'Compare these fingerprints over a trusted channel (in person or a verified call). Only mark verified if every character matches.',
            ),
            const SizedBox(height: 16),
            _FingerprintRow(label: 'Your device', fingerprint: _ownFingerprint),
            const SizedBox(height: 12),
            _FingerprintRow(
              label: widget.peerName,
              fingerprint: peerPrint,
              fallback: 'No session yet — open the chat online to fetch their key.',
            ),
            const SizedBox(height: 16),
            if (trusted == false)
              const Text(
                'Warning: their key changed since you verified. Confirm it is really them before continuing.',
                style: TextStyle(color: Colors.red),
              )
            else if (trusted == true)
              const Text(
                'Verified: fingerprints match your earlier check.',
                style: TextStyle(color: Colors.green),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: peerPrint == null
                        ? null
                        : () async {
                            await SafetyNumber.markVerified(
                              widget.store.preferences,
                              accountId,
                              widget.peerId,
                              peerPrint!,
                            );
                            if (sheetContext.mounted) Navigator.pop(sheetContext);
                          },
                    child: const Text('Mark verified'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      await SafetyNumber.clearVerified(
                        widget.store.preferences,
                        accountId,
                        widget.peerId,
                      );
                      if (sheetContext.mounted) Navigator.pop(sheetContext);
                    },
                    child: const Text('Clear'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _inboxPoll?.cancel();
    _pollTimer?.cancel();
    composer.dispose();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.peerName),

        actions: [
          IconButton(
            tooltip: 'Verify contact',
            onPressed: () => _showVerification(context),
            icon: const Icon(Icons.verified_user_outlined),
          ),
          IconButton(
            tooltip: 'Refresh keys and retry session',
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              try {
                await _publishKeys(force: true);
                await _ensureSession();
                if (!mounted) return;
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text('Keys published, session refreshed'),
                  ),
                );
              } catch (e) {
                if (!mounted) return;
                messenger.showSnackBar(SnackBar(content: Text('Error: $e')));
              }
            },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListenableBuilder(
                    listenable: widget.store,
                    builder: (context, _) {
                      final msgs = widget.store.getSecureConversation(
                        accountId,
                        widget.peerId,
                      );
                      if (msgs.isEmpty) {
                        return const Center(
                          child: Text('No messages yet. Say hello!'),
                        );
                      }
                      return ListView.builder(
                        controller: scroll,
                        reverse: true,
                        padding: const EdgeInsets.all(16),
                        itemCount: msgs.length,
                        itemBuilder: (context, i) {
                          final msg = msgs[i];
                          return _SecureBubble(
                            text: msg.text,
                            mine: msg.mine,
                            time: msg.at,
                          );
                        },
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: composer,
                    minLines: 1,
                    maxLines: 5,
                    maxLength: 4000,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      hintText: 'Write a message…',
                      counterText: '',
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: 'Send',
                  onPressed: _send,
                  icon: const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FingerprintRow extends StatelessWidget {
  const _FingerprintRow({
    required this.label,
    required this.fingerprint,
    this.fallback,
  });
  final String label;
  final String? fingerprint;
  final String? fallback;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.labelMedium),
      const SizedBox(height: 4),
      SelectableText(
        fingerprint == null
            ? fallback ?? 'Unavailable'
            : SafetyNumber.display(fingerprint!),
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
      ),
    ],
  );
}

class _SecureBubble extends StatelessWidget {
  const _SecureBubble({
    required this.text,
    required this.mine,
    required this.time,
  });
  final String text;
  final bool mine;
  final DateTime time;

  @override
  Widget build(BuildContext context) => Align(
    alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
    child: Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.76,
      ),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      decoration: BoxDecoration(
        color: mine ? const Color(0xFF245CDB) : const Color(0xFFE9EDF4),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(mine ? 18 : 4),
          bottomRight: Radius.circular(mine ? 4 : 18),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          SelectableText(
            text,
            style: TextStyle(
              color: mine ? Colors.white : const Color(0xFF22334E),
              fontSize: 15,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${time.hour.toString().padLeft(2, "0")}:${time.minute.toString().padLeft(2, "0")}${mine ? ' \u2022 Local' : ''}',
            style: TextStyle(
              fontSize: 10,
              color: mine ? Colors.white70 : const Color(0xFF66748A),
            ),
          ),
        ],
      ),
    ),
  );
}
