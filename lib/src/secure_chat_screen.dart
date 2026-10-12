import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:video_player/video_player.dart';

import 'chat_store.dart';
import 'contacts_repository.dart';
import 'calling/call_flow.dart';
import 'calling/call_screen.dart';
import 'local_profile.dart';
import 'media/chat_media.dart';
import 'media/media_message.dart';
import 'media/video_player_screen.dart';
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
  late final accountId = widget.client.auth.currentUser!.id;

  RealtimeChannel? _realtime;
  Future<void> _receiveQueue = Future<void>.value();
  final Set<String> _visibleReadIds = {};
  final Set<String> _reportedReadIds = {};
  bool _reading = false;
  int _tickOffset = 0;
  Timer? _pollTimer;
  Timer? _tickTimer;
  bool _loading = true;
  String? _error;
  String? _ownFingerprint;
  String? _peerIdentityKey;
  bool _sendingMedia = false;
  bool _sendingText = false;
  late final ChatMedia media = ChatMedia(widget.client);

  /// Pending quoted reply: (message ref, display name, quoted summary).
  ({String ref, String name, String quote})? _replyTo;

  /// Pinned message refs for the banner. Refreshed on open + pin changes.
  Future<List<String>>? _pinsFuture;

  @override
  void initState() {
    super.initState();
    _pinsFuture = widget.store.securePins(accountId, widget.peerId);
    _bootstrap();
  }

  void _refreshPins() {
    if (!mounted) return;
    setState(() {
      _pinsFuture = widget.store.securePins(accountId, widget.peerId);
    });
  }

  Future<void> _bootstrap() async {
    try {
      final init = await channel.invokeMapMethod<String, dynamic>(
        'initialize',
        {'accountId': accountId},
      );
      // A rotated identity (orphaned keystore entry, corrupt state) has no
      // valid server bundle: force republication and rebuild sessions, or
      // the peer keeps encrypting to a dead identity.
      final freshIdentity = init?['fresh'] == true;
      final status = await channel.invokeMapMethod<String, dynamic>(
        'status',
        {'accountId': accountId},
      );
      _ownFingerprint = status?['fingerprint'] as String?;
      await _publishKeys(force: freshIdentity);
      await _ensureSession();
      await widget.store.loadSecureConversation(accountId, widget.peerId);
      _subscribeRealtime();
      _startPolling();
      // Catch up immediately so an already-waiting envelope does not sit
      // until the first 30s tick.
      await _pollInbox();
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

  Future<void> _ensureSession() => _ensureSessionFor(widget.peerId);

  Future<void> _ensureSessionFor(String peerId) async {
    // Native returns {'hasSession': bool}, not a bare bool.
    final sessionState =
        await channel.invokeMapMethod('signalHasSession', {
          'accountId': accountId,
          'peerId': peerId,
        });
    if (sessionState?['hasSession'] == true) return;
    // Server uses snake_case; the native bridge expects camelCase.
    final claimed =
        await widget.client.rpc(
              'claim_key_bundle',
              params: {'p_user_id': peerId},
            )
            as Map<String, dynamic>;
    if (peerId == widget.peerId) {
      _peerIdentityKey = claimed['identity_key'] as String?;
      if (mounted) setState(() {});
    }
    await channel.invokeMethod('signalProcessBundle', {
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

  void _subscribeRealtime() {
    _realtime = widget.client.channel('envelopes:$accountId')
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

  /// Maximum failed decrypts before a poison envelope is quarantined as a
  /// visible placeholder (and only then acknowledged).
  static const _maxEnvelopeFailures = 5;

  Future<void> _onEnvelope(Map<String, dynamic> record) {
    // Realtime and polling can deliver the same Signal packet concurrently.
    // Serialize decryption as well as storage so the ratchet advances once.
    _receiveQueue = _receiveQueue.catchError((_) {}).then((_) => _receiveEnvelope(record));
    return _receiveQueue;
  }

  Future<void> _receiveEnvelope(Map<String, dynamic> record) async {
    if (!mounted) return;
    final id = record['id'] as String? ?? '';
    final sender = record['sender_id'] as String? ?? '';
    if (sender.isEmpty || id.isEmpty) return;
    // Redelivered rows already stored locally are only missing their ack.
    if (id.isNotEmpty &&
        widget.store.hasSecureEnvelope(accountId, sender, id)) {
      await _ack(id);
      return;
    }
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
    if (plainText == null) {
      // Never ack poison rows blindly: retry the next polls, then quarantine
      // visibly so the user knows a message arrived but could not be opened.
      if (id.isEmpty) return;
      final fails = widget.store.envelopeFailCount(id) + 1;
      await widget.store.recordEnvelopeFailure(id);
      if (fails >= _maxEnvelopeFailures) {
        try {
          await widget.store.addSecureMessage(
            accountId,
            sender,
            '⚠️ A message arrived but could not be decrypted.',
            mine: false,
            envelopeId: id,
          );
          if (mounted) {
            setState(() {});
            _stickToBottom();
          }
          await _ack(id);
        } catch (_) {}
      }
      return;
    }
    try {
      await widget.store.addSecureMessage(
        accountId,
        sender,
        plainText,
        mine: false,
        envelopeId: id.isEmpty ? null : id,
        peerClientId: record['client_message_id'] as String?,
        at: DateTime.tryParse(record['created_at'] as String? ?? ''),
      );
      if (mounted) {
        setState(() {});
        _stickToBottom();
        _refreshPins();
      }
      await _ack(id);
    } catch (_) {
      // Storage failed: do not ack, so the envelope is retried next poll.
    }
  }

  Future<void> _ack(String id) async {
    if (id.isEmpty) return;
    try {
      await widget.client.rpc(
        'ack_messages',
        params: {
          'p_ids': [id],
        },
      );
      _reportedReadIds.remove(id);
      await _flushReadReceipts();
    } catch (_) {}
  }

  void _noticeVisible(SecureMessage message) {
    if (message.mine || message.envelopeId == null) return;
    if (!_visibleReadIds.add(message.envelopeId!)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _flushReadReceipts());
  }

  Future<void> _flushReadReceipts() async {
    if (_reading ||
        !mounted ||
        ModalRoute.of(context)?.isCurrent != true ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    final ids = _visibleReadIds.difference(_reportedReadIds).take(100).toList();
    if (ids.isEmpty) {
      return;
    }
    _reading = true;
    try {
      await widget.client.rpc('mark_messages_read', params: {'p_ids': ids});
      _reportedReadIds.addAll(ids);
    } catch (_) {
      // Retry after connectivity resumes. Never infer a read from a fetch.
      await Future<void>.delayed(const Duration(seconds: 5));
    } finally {
      _reading = false;
    }
  }

  void _startPolling() {
    _pollTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _pollInbox(),
    );
    _tickTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _pollTicks(),
    );
  }

  Future<void> _pollInbox() async {
    try {
      // No clock cursor: fetch every unacked envelope and dedupe by id, so
      // an older undelivered message can never be skipped.
      final result = await widget.client.rpc(
        'fetch_inbox',
        params: {'p_since': null, 'p_limit': 50},
      ) as List<dynamic>;
      for (final record in result.cast<Map<String, dynamic>>()) {
        await _onEnvelope(record);
      }
      await _flushReadReceipts();
    } catch (_) {}
  }

  /// Refreshes sender-side ticks for our recent unacked messages.
  Future<void> _pollTicks() async {
    try {
      final pending = widget.store
          .getSecureConversation(accountId, widget.peerId)
          .where((m) => m.mine && m.clientId.isNotEmpty && m.status != 'read')
          .toList();
      if (pending.isEmpty) return;
      final start = _tickOffset % pending.length;
      final ids = List.generate(min(50, pending.length),
          (i) => pending[(start + i) % pending.length].clientId);
      _tickOffset = (start + ids.length) % pending.length;
      final result = await widget.client.rpc(
        'message_statuses',
        params: {'p_ids': ids},
      ) as List<dynamic>;
      for (final row in result.cast<Map<String, dynamic>>()) {
        final id = row['id'] as String? ?? '';
        final status = row['status'] as String? ?? 'sent';
        if (id.isEmpty) continue;
        await widget.store.updateSecureStatus(
          accountId,
          widget.peerId,
          id,
          status,
          deliveredAt: row['delivered_at'] as String?,
          readAt: row['read_at'] as String?,
        );
      }
      if (mounted) setState(() {});
    } catch (_) {}
  }

  /// Keeps the view pinned to the newest message, but only when the
  /// user is already near the bottom (never yanks reading history).
  void _stickToBottom() {
    if (scroll.hasClients && scroll.offset < 120) {
      scroll.jumpTo(0);
    }
  }

  Future<void> _send() async {
    final text = composer.text.trim();
    if (_sendingText || text.isEmpty || text.length > 4000) return;
    setState(() => _sendingText = true);
    final reply = _replyTo;
    final sent = await _transmit(reply == null ? encodeTextBody(text)
        : encodeReplyBody(reply.ref, text, reply.name, reply.quote));
    if (mounted) {
      setState(() {
        _sendingText = false;
        if (sent && composer.text.trim() == text) {
          composer.clear();
          if (_replyTo == reply) _replyTo = null;
        }
      });
    }
  }

  /// Encrypts [plainText] (raw text or an encoded body), enqueues it for
  /// [toPeer] (this chat's peer by default), and stores the local copy.
  /// Shared by text, media, polls, votes, and forwarded content.
  Future<bool> _transmit(String plainText, {String? toPeer}) async {
    final peerId = toPeer ?? widget.peerId;
    try {
      final random = Random.secure();
      final localId = base64UrlEncode(List<int>.generate(24, (_) => random.nextInt(256)));
      await _ensureSessionFor(peerId);
      final result = await channel.invokeMethod('signalEncrypt', {
        'accountId': accountId,
        'peerId': peerId,
        'plain': base64Encode(utf8.encode(plainText)),
      }) as Map<dynamic, dynamic>;
      // Prefix the Signal message type; the envelope has no type column.
      final queued =
          await widget.client.rpc(
                'enqueue_message',
                params: {
                  'p_recipient_id': peerId,
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
            peerId,
            plainText,
            mine: true,
            clientId: localId,
            at: DateTime.tryParse(queued['created_at'] as String? ?? '') ??
                DateTime.tryParse(queued['expires_at'] as String? ?? '')?.subtract(const Duration(days: 7)),
          );
          if (mounted) {
            setState(() {});
            if (toPeer == null) _stickToBottom();
            _refreshPins();
          }
          return true;
        case 'rate_limited':
          throw StateError('Daily send limit reached. Try again tomorrow.');
        case 'unavailable':
          throw StateError('Contact unavailable. They may have blocked you or removed the connection.');
        default:
          throw StateError('Message rejected by the server.');
      }
    } catch (e) {
      if (mounted) setState(() => _error = e is StateError ? e.message.toString() : 'Message could not be sent. Check your connection and try again.');
      return false;
    }
  }

  Future<void> _pickAndSendImage() async {
    if (_sendingMedia) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            mainAxisSpacing: 20,
            crossAxisSpacing: 8,
            children: [
              _AttachTile(
                icon: Icons.photo_library_outlined,
                color: const Color(0xFF7F66FF),
                label: 'Gallery',
                onTap: () => Navigator.pop(ctx, 'photo_gallery'),
              ),
              _AttachTile(
                icon: Icons.photo_camera_outlined,
                color: const Color(0xFFEC407A),
                label: 'Camera',
                onTap: () => Navigator.pop(ctx, 'photo_camera'),
              ),
              _AttachTile(
                icon: Icons.video_library_outlined,
                color: const Color(0xFF00A884),
                label: 'Video',
                onTap: () => Navigator.pop(ctx, 'video_gallery'),
              ),
              _AttachTile(
                icon: Icons.videocam_outlined,
                color: const Color(0xFF0288D1),
                label: 'Record',
                onTap: () => Navigator.pop(ctx, 'video_camera'),
              ),
              _AttachTile(
                icon: Icons.bar_chart_outlined,
                color: const Color(0xFFF59E0B),
                label: 'Poll',
                onTap: () {
                  Navigator.pop(ctx);
                  _createPoll();
                },
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice.startsWith('video_')) {
      await _pickAndSendVideo(
        choice == 'video_camera',
      );
      return;
    }
    XFile? picked;
    try {
      picked = choice == 'photo_gallery'
          ? await media.pickGalleryImage()
          : await media.pickCameraImage();
    } on Exception catch (e) {
      if (mounted) setState(() => _error = 'Could not open images: $e');
      return;
    }
    if (picked == null || !mounted) return;
    final caption = TextEditingController();
    final send = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Send image'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(
                  File(picked!.path),
                  height: 220,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: caption,
                maxLength: 200,
                decoration: const InputDecoration(
                  hintText: 'Add a caption…',
                  counterText: '',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    if (send != true || !mounted) return;
    setState(() {
      _sendingMedia = true;
      _error = null;
    });
    try {
      final sealed = await media.uploadSealed(
        File(picked.path),
        widget.peerId,
      );
      await _transmit(
        encodeImageBody(
          sealed.path,
          caption.text.trim(),
          key: sealed.key,
          nonce: sealed.nonce,
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Image failed: $e');
      }
    } finally {
      if (mounted) setState(() => _sendingMedia = false);
    }
  }

  Future<void> _createPoll() async {
    final question = TextEditingController();
    final options = [TextEditingController(), TextEditingController()];
    var multi = false;
    final create = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: const Text('Create poll'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: question,
                  maxLength: 200,
                  decoration: const InputDecoration(
                    hintText: 'Ask a question…',
                    counterText: '',
                  ),
                ),
                const SizedBox(height: 8),
                ...options.asMap().entries.map(
                  (entry) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: entry.value,
                            maxLength: 100,
                            decoration: InputDecoration(
                              hintText: 'Option ${entry.key + 1}',
                              counterText: '',
                            ),
                          ),
                        ),
                        if (options.length > 2)
                          IconButton(
                            tooltip: 'Remove option',
                            icon: const Icon(Icons.remove_circle_outline),
                            onPressed: () => setDialog(() {
                              entry.value.dispose();
                              options.removeAt(entry.key);
                            }),
                          ),
                      ],
                    ),
                  ),
                ),
                if (options.length < 8)
                  TextButton.icon(
                    onPressed: () => setDialog(
                      () => options.add(TextEditingController()),
                    ),
                    icon: const Icon(Icons.add),
                    label: const Text('Add option'),
                  ),
                Row(
                  children: [
                    const Expanded(child: Text('Allow multiple answers')),
                    Switch(
                      value: multi,
                      onChanged: (v) => setDialog(() => multi = v),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Send poll'),
            ),
          ],
        ),
      ),
    );
    if (create != true || !mounted) return;
    final q = question.text.trim();
    final opts = options
        .map((c) => c.text.trim())
        .where((o) => o.isNotEmpty)
        .toList();
    if (q.isEmpty || opts.length < 2) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('A poll needs a question and 2–8 options.'),
          ),
        );
      }
      return;
    }
    final pollId =
        '${DateTime.now().microsecondsSinceEpoch}-${accountId.hashCode}';
    await _transmit(encodePollBody(pollId, q, opts, multi: multi));
  }

  Future<void> _pickAndSendVideo(bool fromCamera) async {
    if (_sendingMedia) return;
    XFile? picked;
    try {
      picked = fromCamera
          ? await media.pickCameraVideo()
          : await media.pickGalleryVideo();
    } on Exception catch (e) {
      if (mounted) setState(() => _error = 'Could not open videos: $e');
      return;
    }
    if (picked == null || !mounted) return;
    final file = File(picked.path);
    int durationSec = 0;
    VideoPlayerController? probe;
    try {
      probe = VideoPlayerController.file(file);
      await probe.initialize();
      durationSec = probe.value.duration.inSeconds;
    } catch (_) {
    } finally {
      await probe?.dispose();
    }
    if (!mounted) return;
    final caption = TextEditingController();
    final send = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Send video'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.videocam_outlined),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${picked!.name} • ${durationSec}s',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: caption,
                maxLength: 200,
                decoration: const InputDecoration(
                  hintText: 'Add a caption…',
                  counterText: '',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    if (send != true || !mounted) return;
    setState(() {
      _sendingMedia = true;
      _error = null;
    });
    try {
      final sealed = await media.uploadSealedVideo(file, widget.peerId);
      await _transmit(
        encodeVideoBody(
          sealed.path,
          caption.text.trim(),
          key: sealed.key,
          nonce: sealed.nonce,
          thumbPath: sealed.thumbPath.isEmpty ? null : sealed.thumbPath,
          thumbKey: sealed.thumbKey.isEmpty ? null : sealed.thumbKey,
          thumbNonce: sealed.thumbNonce.isEmpty ? null : sealed.thumbNonce,
          durationSec: durationSec,
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Video failed: $e');
      }
    } finally {
      if (mounted) setState(() => _sendingMedia = false);
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

  String _quoteSummary(MediaBody body) {
    if (body.isImage) return body.text.isEmpty ? 'Photo' : body.text;
    if (body.isVideo) return body.text.isEmpty ? 'Video' : body.text;
    if (body.isPoll) return body.question ?? 'Poll';
    if (body.isReply) return body.text;
    final t = body.text;
    return t.length > 80 ? '${t.substring(0, 80)}…' : t;
  }

  void _beginReply(SecureMessage msg) {
    final body = parseMessageBody(msg.text);
    if (body.isDelete || body.isVote || body.isTombstone) return;
    setState(() => _replyTo = (
      ref: msg.ref,
      name: msg.mine ? (widget.profile.name.isEmpty ? 'Sender' : widget.profile.name) : widget.peerName,
      quote: _quoteSummary(body),
    ));
  }

  /// WhatsApp-style long-press menu for one message.
  Future<void> _messageActions(SecureMessage msg) async {
    final body = parseMessageBody(msg.text);
    if (body.isTombstone) return;
    final stars = await widget.store.secureStars(
      accountId,
      widget.peerId,
    );
    final pins = await widget.store.securePins(accountId, widget.peerId);
    if (!mounted) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!body.isVote && !body.isDelete)
              ListTile(
                leading: const Icon(Icons.reply_outlined),
                title: const Text('Reply'),
                onTap: () => Navigator.pop(ctx, 'reply'),
              ),
            if (body.text.isNotEmpty || body.question != null)
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: const Text('Copy'),
                onTap: () => Navigator.pop(ctx, 'copy'),
              ),
            ListTile(
              leading: const Icon(Icons.forward_outlined),
              title: const Text('Forward'),
              onTap: () => Navigator.pop(ctx, 'forward'),
            ),
            ListTile(
              leading: Icon(
                stars.contains(msg.ref)
                    ? Icons.star
                    : Icons.star_outline,
              ),
              title: Text(
                stars.contains(msg.ref) ? 'Unstar' : 'Star',
              ),
              onTap: () => Navigator.pop(ctx, 'star'),
            ),
            ListTile(
              leading: const Icon(Icons.push_pin_outlined),
              title: Text(pins.contains(msg.ref) ? 'Unpin' : 'Pin'),
              onTap: () => Navigator.pop(ctx, 'pin'),
            ),
            if (msg.mine) ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Info'),
              onTap: () => Navigator.pop(ctx, 'info'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete for me'),
              onTap: () => Navigator.pop(ctx, 'deleteme'),
            ),
            if (msg.canDeleteForEveryone(DateTime.now()))
              ListTile(
                leading: Icon(
                  Icons.delete_forever_outlined,
                  color: Theme.of(ctx).colorScheme.error,
                ),
                title: const Text('Delete for everyone'),
                onTap: () => Navigator.pop(ctx, 'deleteall'),
              ),
          ],
        )),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'reply':
        _beginReply(msg);
      case 'copy':
        final copyText = body.isPoll
            ? '${body.question ?? ''}\n${(body.options ?? []).join('\n')}'
            : (body.isReply
                  ? body.text
                  : (body.text.isNotEmpty
                        ? body.text
                        : _quoteSummary(body)));
        await Clipboard.setData(ClipboardData(text: copyText));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Copied to clipboard')),
          );
        }
      case 'forward':
        await _forwardPicker(body);
      case 'star':
        await widget.store.toggleSecureStar(
          accountId,
          widget.peerId,
          msg.ref,
        );
        final starred = (await widget.store.secureStars(accountId, widget.peerId)).contains(msg.ref);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                starred
                    ? 'Starred.'
                    : 'Unstarred.',
              ),
            ),
          );
        }
      case 'pin':
        if (pins.contains(msg.ref)) {
          await widget.store.unpinSecureMessage(
            accountId,
            widget.peerId,
            msg.ref,
          );
        } else {
          final ok = await widget.store.pinSecureMessage(
            accountId,
            widget.peerId,
            msg.ref,
          );
          if (!ok && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Pin up to 3 messages.')),
            );
          }
        }
        _refreshPins();
      case 'info':
        _showInfo(msg);
      case 'deleteme':
        await widget.store.removeSecureMessage(
          accountId,
          widget.peerId,
          msg.ref,
        );
        if (mounted) setState(() {});
        _refreshPins();
      case 'deleteall':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Delete for everyone?'),
            content: const Text(
              'Ask recipients to remove this message. They may have already read or saved it.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error,
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          if (!msg.canDeleteForEveryone(DateTime.now())) {
            if (mounted) setState(() => _error = 'The one-hour deletion window has ended.');
            return;
          }
          await _transmit(encodeDeleteBody(msg.clientId));
        }
    }
  }

  /// Contact picker for forwarding into another encrypted chat.
  Future<void> _forwardPicker(MediaBody body) async {
    List<CloudContact> contacts = [];
    try {
      contacts = (await SupabaseContactsRepository(
            widget.client,
          ).contacts())
          .where((c) => c.status == 'accepted')
          .toList();
    } catch (_) {
      if (mounted) setState(() => _error = 'Contacts could not be loaded. Try again.');
      return;
    }
    if (!mounted) return;
    final target = await showModalBottomSheet<CloudContact>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Forward to…',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            if (contacts.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('No connected contacts yet.'),
              ),
            for (final c in contacts)
              ListTile(
                leading: CircleAvatar(
                  child: Text(
                    c.name.isEmpty ? '?' : c.name[0].toUpperCase(),
                  ),
                ),
                title: Text(c.name),
                subtitle: Text('@${c.username}'),
                onTap: () => Navigator.pop(ctx, c),
              ),
          ],
        )),
      ),
    );
    if (target == null || !mounted) return;
    setState(() => _error = null);
    try {
      final forwarded = await media.forwardBody(body, target.userId);
      final sent = await _transmit(forwarded, toPeer: target.userId);
      if (sent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Forwarded to ${target.name}.')),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'The message could not be forwarded. Try again.');
    }
  }

  /// Sent / delivered / read roster for one of our messages.
  void _showInfo(SecureMessage msg) {
    String fmt(String? iso) {
      if (iso == null || iso.isEmpty) return '—';
      try {
        final at = DateTime.parse(iso).toLocal();
        return '${at.day.toString().padLeft(2, '0')}/${at.month.toString().padLeft(2, '0')}/${at.year} '
            '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
      } catch (_) {
        return '—';
      }
    }

    final sent = fmt(msg.at.toIso8601String());
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Message info',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 16),
              _InfoRow(
                icon: Icons.check,
                label: 'Sent',
                value: sent,
              ),
              _InfoRow(
                icon: Icons.done_all,
                label: 'Delivered',
                value: msg.mine ? fmt(msg.deliveredAt) : '—',
              ),
              _InfoRow(
                icon: Icons.done_all,
                label: 'Read',
                value: msg.mine ? fmt(msg.readAt) : '—',
                accent: true,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Every starred message in this chat, newest last.
  Future<void> _showStarred() async {
    final stars = await widget.store.secureStars(
      accountId,
      widget.peerId,
    );
    if (!mounted) return;
    final messages = widget.store.getSecureConversation(
      accountId,
      widget.peerId,
    );
    final starred = messages
        .where((m) => stars.contains(m.ref))
        .toList();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Starred messages'),
        content: SizedBox(
          width: double.maxFinite,
          child: starred.isEmpty
              ? const Text('Nothing starred yet. Long-press any message.')
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: starred.length,
                  itemBuilder: (_, i) {
                    final body = parseMessageBody(starred[i].text);
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(
                        Icons.star,
                        size: 18,
                        color: Color(0xFFF59E0B),
                      ),
                      title: Text(
                        _quoteSummary(body),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// Every pinned message with per-row unpin.
  Future<void> _showPinned(List<String> pins) async {
    final messages = widget.store.getSecureConversation(
      accountId,
      widget.peerId,
    );
    SecureMessage? lookup(String ref) {
      for (final m in messages) {
        if (m.ref == ref || m.clientId == ref || m.envelopeId == ref) {
          return m;
        }
      }
      return null;
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: const Text('Pinned messages'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final ref in pins)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(
                      Icons.push_pin_outlined,
                      size: 18,
                    ),
                    title: Text(
                      _quoteSummary(
                        parseMessageBody(lookup(ref)?.text ?? ''),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      tooltip: 'Unpin',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () async {
                        await widget.store.unpinSecureMessage(
                          accountId,
                          widget.peerId,
                          ref,
                        );
                        pins.remove(ref);
                        setDialog(() {});
                        _refreshPins();
                      },
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _realtime?.unsubscribe();
    _pollTimer?.cancel();
    _tickTimer?.cancel();
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
            tooltip: 'Voice call',
            onPressed: () => startOutgoingCall(
              context,
              client: widget.client,
              peerId: widget.peerId,
              peerName: widget.peerName,
              type: CallType.voice,
            ),
            icon: const Icon(Icons.call_outlined),
          ),
          IconButton(
            tooltip: 'Video call',
            onPressed: () => startOutgoingCall(
              context,
              client: widget.client,
              peerId: widget.peerId,
              peerName: widget.peerName,
              type: CallType.video,
            ),
            icon: const Icon(Icons.videocam_outlined),
          ),
          PopupMenuButton<String>(
            tooltip: 'More options',
            icon: const Icon(Icons.more_vert),
            onSelected: (value) async {
              switch (value) {
                case 'starred':
                  await _showStarred();
                case 'verify':
                  _showVerification(context);
                case 'refresh':
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
                case 'link':
                  final link =
                      'https://open.chat/invite?account=$accountId&peer=${widget.peerId}';
                  Clipboard.setData(ClipboardData(text: link));
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Link copied to clipboard')),
                    );
                  }
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'starred', child: ListTile(
                contentPadding: EdgeInsets.zero, leading: Icon(Icons.star_outline), title: Text('Starred messages'),
              )),
              PopupMenuItem(
                value: 'verify',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.verified_user_outlined),
                  title: Text('Verify contact'),
                ),
              ),
              PopupMenuItem(
                value: 'refresh',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.refresh),
                  title: Text('Refresh encryption'),
                ),
              ),
              PopupMenuItem(
                value: 'link',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.link),
                  title: Text('Copy invite link'),
                ),
              ),
            ],
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
                      // Ballots and delete markers travel as messages but never
                      // render as bubbles; ballots feed tallies, markers are
                      // applied then dropped.
                      final visible = msgs
                          .where(
                            (m) {
                              final kind = parseMessageBody(m.text);
                              return !kind.isVote && !kind.isDelete;
                            },
                          )
                          .toList();
                      if (visible.isEmpty) {
                        return const Center(
                          child: Text('No messages yet. Say hello!'),
                        );
                      }
                      final records = msgs
                          .map((m) => (text: m.text, mine: m.mine))
                          .toList();
                      // Newest at the bottom: the reversed list lays index
                      // 0 at the bottom edge, so feed newest-first.
                      final ordered = visible.reversed.toList();
                      return ListView.builder(
                        controller: scroll,
                        reverse: true,
                        padding: const EdgeInsets.all(16),
                        itemCount: ordered.length,
                        itemBuilder: (context, i) {
                          final msg = ordered[i];
                          _noticeVisible(msg);
                          final body = parseMessageBody(msg.text);
                          Widget bubble;
                          if (body.isTombstone) {
                            bubble = _SecureBubble(
                              text: 'This message was deleted',
                              deleted: true,
                              mine: msg.mine,
                              time: msg.at.toLocal(),
                            );
                          } else if (body.isReply &&
                              body.refId != null &&
                              body.refId!.isNotEmpty) {
                            bubble = _SecureBubble(
                              text: body.text,
                              quoteName: body.quoteName ?? '',
                              quoteText: body.quoteText ?? '',
                              mine: msg.mine,
                              time: msg.at.toLocal(),
                              status: msg.status,
                            );
                          } else if (body.isPoll &&
                              body.pollId != null &&
                              body.question != null &&
                              body.options != null) {
                            bubble = _SecurePollBubble(
                              pollId: body.pollId!,
                              question: body.question!,
                              options: body.options!,
                              multi: body.multi,
                              tally: tallyPoll(
                                body.pollId!,
                                body.options!.length,
                                records,
                              ),
                              mine: msg.mine,
                              time: msg.at.toLocal(),
                              status: msg.status,
                              onVote: (choices) => _transmit(
                                encodeVoteBody(body.pollId!, choices),
                              ),
                            );
                          } else if (body.isVideo && body.path != null) {
                            bubble = _SecureVideoBubble(
                              client: widget.client,
                              path: body.path!,
                              caption: body.text,
                              imageKey: body.key,
                              imageNonce: body.nonce,
                              thumbPath: body.thumbPath,
                              thumbKey: body.thumbKey,
                              thumbNonce: body.thumbNonce,
                              durationSec: body.durationSec,
                              mine: msg.mine,
                              time: msg.at.toLocal(),
                              status: msg.status,
                            );
                          } else if (body.isImage && body.path != null) {
                            bubble = _SecureImageBubble(
                              client: widget.client,
                              path: body.path!,
                              caption: body.text,
                              imageKey: body.key,
                              imageNonce: body.nonce,
                              mine: msg.mine,
                              time: msg.at.toLocal(),
                              status: msg.status,
                            );
                          } else {
                            bubble = _SecureBubble(
                              text: body.text,
                              mine: msg.mine,
                              time: msg.at.toLocal(),
                              status: msg.status,
                            );
                          }
                          if (body.forwarded && !body.isTombstone) {
                            bubble = Column(
                              crossAxisAlignment: msg.mine
                                  ? CrossAxisAlignment.end
                                  : CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 2),
                                  child: Text(
                                    'Forwarded',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontStyle: FontStyle.italic,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                                  ),
                                ),
                                bubble,
                              ],
                            );
                          }
                          return GestureDetector(
                            key: ValueKey(msg.ref),
                            onHorizontalDragEnd: body.isTombstone ? null : (details) {
                              if ((details.primaryVelocity ?? 0) > 100) _beginReply(msg);
                            },
                            onLongPress: body.isTombstone
                                ? null
                                : () => _messageActions(msg),
                            child: bubble,
                          );
                        },
                      );
                    },
                  ),
          ),
          FutureBuilder<List<String>>(
            future: _pinsFuture,
            builder: (context, snapshot) {
              final pins = snapshot.data ?? const <String>[];
              if (pins.isEmpty) return const SizedBox.shrink();
              return InkWell(
                onTap: () => _showPinned(pins),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(
                        color: Theme.of(context).colorScheme.primary,
                        width: 4,
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.push_pin_outlined, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '📌 Pinned (${pins.length}/3) — tap to view',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_replyTo != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      border: Border(
                        left: BorderSide(
                          color: Theme.of(context).colorScheme.primary,
                          width: 4,
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _replyTo!.name,
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.primary,
                                ),
                              ),
                              Text(
                                _replyTo!.quote,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Cancel reply',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () =>
                              setState(() => _replyTo = null),
                        ),
                      ],
                    ),
                  ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                IconButton(
                  tooltip: 'Attach photo, video, or poll',
                  onPressed: _sendingMedia ? null : _pickAndSendImage,
                  icon: _sendingMedia
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.attach_file),
                ),
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
                   onPressed: _sendingText ? null : _send,
                  icon: const Icon(Icons.send),
                ),
              ],
            ),
            ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.label, required this.value, this.accent = false});
  final IconData icon;
  final String label;
  final String value;
  final bool accent;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon, color: accent ? Theme.of(context).colorScheme.primary : null),
    title: Text(label), subtitle: Text(value),
  );
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

/// Delivery ticks for our own messages: single check sent, double
/// delivered, blue double read. Mirrors the server receipt states.
class _Ticks {
  static String glyph(String status) => switch (status) {
    'read' => ' ✓✓',
    'delivered' => ' ✓✓',
    _ => ' ✓',
  };
  static Color color(String status, bool mine) {
    if (!mine) return const Color(0xFF66748A);
    if (status == 'read') return const Color(0xFF7DD3FC);
    return Colors.white70;
  }
}

/// Image message bubble. The image bytes come from the private `chat-media`
/// bucket over a short-lived signed URL; the path itself arrived inside the
/// Signal-encrypted message.
class _SecureImageBubble extends StatefulWidget {
  const _SecureImageBubble({
    required this.client,
    required this.path,
    required this.caption,
    required this.mine,
    required this.time,
    this.status = 'sent',
    this.imageKey,
    this.imageNonce,
  });
  final SupabaseClient client;
  final String path;
  final String caption;
  final bool mine;
  final DateTime time;
  final String status;

  /// Base64 sealed file key/nonce. Null on legacy unsealed uploads.
  final String? imageKey;
  final String? imageNonce;
  @override
  State<_SecureImageBubble> createState() => _SecureImageBubbleState();
}

class _SecureImageBubbleState extends State<_SecureImageBubble> {
  /// Plaintext lives only in memory: sealed downloads are decrypted after
  /// fetch, legacy downloads are raw bytes.
  late final Future<Uint8List> _bytes = () {
    final media = ChatMedia(widget.client);
    if (widget.imageKey != null && widget.imageNonce != null) {
      return media.downloadSealed(
        widget.path,
        widget.imageKey!,
        widget.imageNonce!,
      );
    }
    return media.downloadRaw(widget.path);
  }();

  void _openLightbox(Uint8List bytes) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(16),
        child: Stack(
          alignment: Alignment.topRight,
          children: [
            InteractiveViewer(child: Image.memory(bytes)),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 28),
              onPressed: () => Navigator.of(ctx).pop(),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: widget.mine ? Alignment.centerRight : Alignment.centerLeft,
    child: Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.72,
      ),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: widget.mine
            ? const Color(0xFF245CDB)
            : const Color(0xFFE9EDF4),
        borderRadius: const BorderRadius.all(Radius.circular(18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          FutureBuilder<Uint8List>(
            future: _bytes,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const SizedBox(
                  height: 160,
                  child: Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                );
              }
              if (snapshot.hasError || !snapshot.hasData) {
                return const SizedBox(
                  height: 120,
                  child: Center(child: Icon(Icons.broken_image_outlined)),
                );
              }
              final bytes = snapshot.data!;
              return GestureDetector(
                onTap: () => _openLightbox(bytes),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  // WhatsApp-style fixed preview: tap opens the full image.
                  child: SizedBox(
                    height: 260,
                    width: double.infinity,
                    child: Image.memory(
                      bytes,
                      fit: BoxFit.cover,
                      errorBuilder: (context, _, _) => const SizedBox(
                        height: 120,
                        child: Center(child: Icon(Icons.broken_image_outlined)),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          if (widget.caption.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
              child: SelectableText(
                widget.caption,
                style: TextStyle(
                  color: widget.mine
                      ? Colors.white
                      : const Color(0xFF22334E),
                  fontSize: 14,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 2, 10, 6),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text:
                        '${widget.time.hour.toString().padLeft(2, '0')}:${widget.time.minute.toString().padLeft(2, '0')}',
                    style: TextStyle(
                      fontSize: 10,
                      color: widget.mine
                          ? Colors.white70
                          : const Color(0xFF66748A),
                    ),
                  ),
                  if (widget.mine)
                    TextSpan(
                      text: _Ticks.glyph(widget.status),
                      style: TextStyle(
                        fontSize: 10,
                        color: _Ticks.color(widget.status, true),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Sealed video bubble: thumbnail preview with duration + play overlay.
/// Tapping downloads, unseals, and opens fullscreen playback.
class _SecureVideoBubble extends StatefulWidget {
  const _SecureVideoBubble({
    required this.client,
    required this.path,
    required this.caption,
    required this.mine,
    required this.time,
    this.status = 'sent',
    this.imageKey,
    this.imageNonce,
    this.thumbPath,
    this.thumbKey,
    this.thumbNonce,
    this.durationSec = 0,
  });
  final SupabaseClient client;
  final String path;
  final String caption;
  final bool mine;
  final DateTime time;
  final String status;
  final String? imageKey;
  final String? imageNonce;
  final String? thumbPath;
  final String? thumbKey;
  final String? thumbNonce;
  final int durationSec;
  @override
  State<_SecureVideoBubble> createState() => _SecureVideoBubbleState();
}

class _SecureVideoBubbleState extends State<_SecureVideoBubble> {
  late final Future<Uint8List?> _thumb = () async {
    if (widget.thumbPath != null &&
        widget.thumbPath!.isNotEmpty &&
        widget.thumbKey != null &&
        widget.thumbNonce != null) {
      try {
        return await ChatMedia(
          widget.client,
        ).downloadSealed(widget.thumbPath!, widget.thumbKey!, widget.thumbNonce!);
      } catch (_) {
        return null;
      }
    }
    return null;
  }();

  String get _durationLabel {
    final m = widget.durationSec ~/ 60;
    final s = widget.durationSec % 60;
    return m > 0
        ? '$m:${s.toString().padLeft(2, '0')}'
        : '0:${s.toString().padLeft(2, '0')}';
  }

  Future<void> _play() async {
    if (widget.imageKey == null || widget.imageNonce == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = await ChatMedia(
        widget.client,
      ).downloadSealed(widget.path, widget.imageKey!, widget.imageNonce!);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => SealedVideoScreen(
            bytes: bytes,
            caption: widget.caption,
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Could not load this video.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: widget.mine ? Alignment.centerRight : Alignment.centerLeft,
    child: Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.72,
      ),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: widget.mine
            ? const Color(0xFF245CDB)
            : const Color(0xFFE9EDF4),
        borderRadius: const BorderRadius.all(Radius.circular(18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: _play,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                height: 170,
                width: double.infinity,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    FutureBuilder<Uint8List?>(
                      future: _thumb,
                      builder: (context, snapshot) => snapshot.hasData
                          ? Image.memory(snapshot.data!, fit: BoxFit.cover)
                          : Container(
                              color: Colors.black38,
                              child: const Center(
                                child: Icon(
                                  Icons.movie_outlined,
                                  color: Colors.white54,
                                  size: 48,
                                ),
                              ),
                            ),
                    ),
                    const Center(
                      child: CircleAvatar(
                        backgroundColor: Colors.black54,
                        child: Icon(
                          Icons.play_arrow,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _durationLabel,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (widget.caption.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
              child: SelectableText(
                widget.caption,
                style: TextStyle(
                  color: widget.mine
                      ? Colors.white
                      : const Color(0xFF22334E),
                  fontSize: 14,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 2, 10, 6),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text:
                        '${widget.time.hour.toString().padLeft(2, '0')}:${widget.time.minute.toString().padLeft(2, '0')}',
                    style: TextStyle(
                      fontSize: 10,
                      color: widget.mine
                          ? Colors.white70
                          : const Color(0xFF66748A),
                    ),
                  ),
                  if (widget.mine)
                    TextSpan(
                      text: _Ticks.glyph(widget.status),
                      style: TextStyle(
                        fontSize: 10,
                        color: _Ticks.color(widget.status, true),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// WhatsApp-style attach grid tile: colored round icon over a label.
class _AttachTile extends StatelessWidget {
  const _AttachTile({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(16),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircleAvatar(
          radius: 28,
          backgroundColor: color,
          child: Icon(icon, color: Colors.white, size: 26),
        ),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    ),
  );
}

/// Encrypted poll bubble. Votes travel as ballots inside the Signal
/// stream; the tally aggregates the latest ballot per side live.
class _SecurePollBubble extends StatefulWidget {
  const _SecurePollBubble({
    required this.pollId,
    required this.question,
    required this.options,
    required this.multi,
    required this.tally,
    required this.mine,
    required this.time,
    required this.status,
    required this.onVote,
  });
  final String pollId;
  final String question;
  final List<String> options;
  final bool multi;
  final PollTally tally;
  final bool mine;
  final DateTime time;
  final String status;
  final ValueChanged<List<int>> onVote;
  @override
  State<_SecurePollBubble> createState() => _SecurePollBubbleState();
}

class _SecurePollBubbleState extends State<_SecurePollBubble> {
  late Set<int> selected = widget.tally.mine.toSet();

  @override
  Widget build(BuildContext context) {
    final counts = widget.tally.counts;
    final total = widget.tally.total;
    return Align(
      alignment: widget.mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
        decoration: BoxDecoration(
          color: widget.mine
              ? const Color(0xFF245CDB)
              : const Color(0xFFE9EDF4),
          borderRadius: const BorderRadius.all(Radius.circular(18)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.bar_chart_outlined, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    widget.question,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      color: widget.mine
                          ? Colors.white
                          : const Color(0xFF22334E),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ...widget.options.asMap().entries.map((entry) {
              final i = entry.key;
              final count = i < counts.length ? counts[i] : 0;
              final frac = total == 0 ? 0.0 : count / total;
              final isMine = selected.contains(i);
              final fg = widget.mine
                  ? Colors.white
                  : const Color(0xFF22334E);
              return InkWell(
                onTap: () => setState(() {
                  if (widget.multi) {
                    isMine ? selected.remove(i) : selected.add(i);
                  } else {
                    selected = {i};
                  }
                }),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            widget.multi
                                ? (isMine
                                      ? Icons.check_box
                                      : Icons.check_box_outline_blank)
                                : (isMine
                                      ? Icons.radio_button_checked
                                      : Icons.radio_button_unchecked),
                            size: 18,
                            color: fg,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              entry.value,
                              style: TextStyle(fontSize: 14, color: fg),
                            ),
                          ),
                          Text(
                            '$count',
                            style: TextStyle(fontSize: 13, color: fg),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: frac,
                          minHeight: 6,
                          backgroundColor: widget.mine
                              ? Colors.white24
                              : Colors.black12,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            widget.mine
                                ? Colors.white
                                : Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '$total vote${total == 1 ? '' : 's'}${widget.multi ? ' • multiple choice' : ''}',
                    style: TextStyle(
                      fontSize: 11,
                      color: widget.mine
                          ? Colors.white70
                          : const Color(0xFF66748A),
                    ),
                  ),
                ),
                TextButton(
                  onPressed: selected.isEmpty
                      ? null
                      : () => widget.onVote(selected.toList()..sort()),
                  child: const Text('Vote'),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text:
                          '${widget.time.hour.toString().padLeft(2, '0')}:${widget.time.minute.toString().padLeft(2, '0')}',
                      style: TextStyle(
                        fontSize: 10,
                        color: widget.mine
                            ? Colors.white70
                            : const Color(0xFF66748A),
                      ),
                    ),
                    if (widget.mine)
                      TextSpan(
                        text: _Ticks.glyph(widget.status),
                        style: TextStyle(
                          fontSize: 10,
                          color: _Ticks.color(widget.status, true),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SecureBubble extends StatelessWidget {
  const _SecureBubble({
    required this.text,
    required this.mine,
    required this.time,
    this.status = 'sent',
    this.quoteName,
    this.quoteText,
    this.deleted = false,
  });
  final String text;
  final bool mine;
  final DateTime time;
  final String status;
  final String? quoteName;
  final String? quoteText;
  final bool deleted;

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
        borderRadius: const BorderRadius.all(Radius.circular(18)),
        boxShadow: mine ? [BoxShadow(color: Colors.black26, blurRadius: 2, offset: const Offset(0, 1))] : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (quoteText != null) Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: mine ? Colors.white12 : Colors.black12,
              border: Border(left: BorderSide(color: mine ? Colors.white70 : const Color(0xFF245CDB), width: 3)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(quoteName ?? '', style: TextStyle(fontWeight: FontWeight.bold, color: mine ? Colors.white : const Color(0xFF22334E))),
              Text(quoteText!, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: mine ? Colors.white70 : const Color(0xFF22334E))),
            ]),
          ),
          Text(
            text,
            style: TextStyle(
              color: mine ? Colors.white : const Color(0xFF22334E),
              fontStyle: deleted ? FontStyle.italic : FontStyle.normal,
              fontSize: 15,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 6),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text:
                      '${time.hour.toString().padLeft(2, "0")}:${time.minute.toString().padLeft(2, "0")}',
                  style: TextStyle(
                    fontSize: 10,
                    color: mine
                        ? Colors.white70
                        : const Color(0xFF66748A),
                  ),
                ),
                if (mine && !deleted)
                  TextSpan(
                    text: _Ticks.glyph(status),
                    style: TextStyle(
                      fontSize: 10,
                      color: _Ticks.color(status, true),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
