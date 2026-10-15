import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:video_player/video_player.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as device_contacts;
import 'package:geolocator/geolocator.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import 'chat_store.dart';
import 'chat_lock.dart';
import 'chat_preferences.dart';
import 'chat/day_label.dart';
import 'contacts_repository.dart';
import 'calling/call_flow.dart';
import 'calling/call_screen.dart';
import 'local_profile.dart';
import 'media/chat_media.dart';
import 'media/document_transfer.dart';
import 'media/document_bubble.dart';
import 'media/share_bubbles.dart';
import 'media/view_once_screen.dart';
import 'media/media_message.dart';
import 'media/video_player_screen.dart';
import 'push/push_service.dart';
import 'push/notify_service.dart';
import 'voice_notes/voice_note_bubble.dart';
import 'voice_notes/voice_note_recorder.dart';
import 'widgets/message_format.dart';
import 'widgets/status_ticks.dart';
import 'widgets/whatsapp_bubble.dart';
import 'security/envelope_codec.dart';
import 'security/safety_number.dart';
import 'security/app_lock.dart';
import 'chat/typing_presence.dart';
import 'widgets/whatsapp_wallpaper.dart';

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
    this.peerAvatarUrl,
    this.testing = false,
  });
  final LocalProfile profile;
  final ChatStore store;
  final PushService push;
  final SupabaseClient client;
  final String peerId;
  final String peerName;
  final String peerUsername;
  final String? peerAvatarUrl;
  final bool testing;

  @override
  State<SecureChatScreen> createState() => _SecureChatScreenState();
}

class _SecureChatScreenState extends State<SecureChatScreen>
    with WidgetsBindingObserver {
  bool _accessGranted = false;
  bool _bootstrapped = false;
  String get _lockKey => 'openchat.secureLock.v1.$accountId.${widget.peerId}';
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
  TransferControl? _documentControl;
  double _documentProgress = 0;
  late final documents = DocumentTransfer(
    SupabaseChunkStorage(widget.client),
    accountId,
  );
  bool _sendingText = false;
  late final ChatMedia media = ChatMedia(
    widget.client,
    preferences: widget.store.preferences,
  );
  late final ChatPreferences _chatPreferences = ChatPreferences(
    widget.store.preferences,
  );
  late ChatWallpaperPreset _wallpaperPreset;

  /// Pending quoted reply: (message ref, display name, quoted summary).
  ({String ref, String name, String quote})? _replyTo;

  /// Pending in-place correction: (target ref, original text).
  ({String ref, String text})? _editing;

  /// Floating WhatsApp-style reaction bar (tap a bubble). Dismissed on
  /// selection, outside tap, scroll, or dispose — never stacked twice.
  OverlayEntry? _reactBar;

  /// Last tap-down position, used to anchor the reaction bar near the
  /// bubble. Falls back to upper-center when unavailable.
  Offset? _tapPos;

  /// In-chat search state. Filters the rendered list; history untouched.
  bool _searching = false;
  String _searchQuery = '';
  DateTime? _searchDate;
  String? _searchMedia; // null=all, img,vid,voice,doc,contact,loc,poll
  final searchBox = TextEditingController();

  /// Pinned message refs for the banner. Refreshed on open + pin changes.
  Future<List<String>>? _pinsFuture;

  /// Scroll-to-bottom jump button visibility (reversed list: offset>300).
  bool _showJump = false;

  /// Typing/presence indicator for 1:1 chats.
  TypingPresence? _typingPresence;

  /// Contact-list state for this peer. Null = not in the list yet, which
  /// explains undelivered messages, failed calls and invisible profiles:
  /// everything peer-visible needs an accepted contact request.
  CloudContact? _peerContact;
  bool _contactBusy = false;

  @override
  void initState() {
    super.initState();
    _wallpaperPreset = _chatPreferences.wallpaperFor(widget.peerId);
    WidgetsBinding.instance.addObserver(this);
    _accessGranted = widget.store.preferences.getBool(_lockKey) != true;
    // This chat is visible: suppress its notifications, clear its badge
    // and unread flag, and restore any unsent draft.
    NotifyService.instance.openChats.add(widget.peerId);
    NotifyService.instance.cancelChat(widget.peerId);
    widget.store.setSecureUnread(accountId, widget.peerId, false);
    composer.text = widget.store.secureDraft(accountId, widget.peerId);
    composer.addListener(_saveDraft);
    composer.addListener(() {
      if (composer.text.isNotEmpty) {
        _typingPresence?.onKeystroke();
      } else {
        _typingPresence?.stopTyping();
      }
    });
    scroll.addListener(_onScroll);
    _pinsFuture = widget.store.securePins(accountId, widget.peerId);
    if (_accessGranted) {
      _bootstrapped = true;
      _bootstrap();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed &&
        widget.store.preferences.getBool(_lockKey) == true) {
      _hideReactBar();
      if (mounted) setState(() => _accessGranted = false);
    }
  }

  Future<void> _unlockChat() async {
    if (await ChatLock.promptVerify(context) && mounted) {
      setState(() => _accessGranted = true);
      if (!_bootstrapped) {
        _bootstrapped = true;
        await _bootstrap();
      }
    }
  }

  void _saveDraft() {
    widget.store.setSecureDraft(accountId, widget.peerId, composer.text);
  }

  void _refreshPins() {
    if (!mounted) return;
    setState(() {
      _pinsFuture = widget.store.securePins(accountId, widget.peerId);
    });
  }

  /// Loads this peer's contact-list state. Everything peer-visible
  /// (delivery, calls, profile, status) needs an accepted request.
  Future<void> _refreshPeerContact() async {
    try {
      final contacts =
          await SupabaseContactsRepository(widget.client).contacts();
      if (!mounted) return;
      setState(() {
        _peerContact = null;
        for (final c in contacts) {
          if (c.userId == widget.peerId) _peerContact = c;
        }
      });
    } catch (_) {}
  }

  bool get _peerConnected => _peerContact?.status == 'accepted';

  Future<void> _invitePeer() async {
    if (_contactBusy || widget.peerUsername.isEmpty) return;
    setState(() => _contactBusy = true);
    try {
      final result = await SupabaseContactsRepository(widget.client)
          .invite(widget.peerUsername);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(switch (result) {
            'sent' => 'Invite sent to @${widget.peerUsername}.',
            'already_sent' => 'Invite already pending.',
            'already_connected' => 'Already connected.',
            'incoming_pending' => 'They invited you already — accept below.',
            _ => result,
          }),
        ),
      );
      await _refreshPeerContact();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Invite failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _contactBusy = false);
    }
  }

  Future<void> _acceptPeerInvite() async {
    final requestId = _peerContact?.requestId;
    if (_contactBusy || requestId == null) return;
    setState(() => _contactBusy = true);
    try {
      await SupabaseContactsRepository(widget.client).respond(requestId, true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connected. Messages and calls now work.')),
      );
      await _refreshPeerContact();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Accept failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _contactBusy = false);
    }
  }

  Future<void> _chooseWallpaper() async {
    final picked = await chooseChatWallpaper(context, _wallpaperPreset);
    if (picked == null || !mounted) return;
    await _chatPreferences.setWallpaper(widget.peerId, picked);
    setState(() => _wallpaperPreset = picked);
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
      final status = await channel.invokeMapMethod<String, dynamic>('status', {
        'accountId': accountId,
      });
      _ownFingerprint = status?['fingerprint'] as String?;
      await _publishKeys(force: freshIdentity);
      try {
        await _ensureSession();
      } catch (e) {
        // A broken session must not take down receiving: subscribe and poll
        // anyway; sending heals itself via _transmit's retry.
        if (mounted) setState(() => _error = _friendlySendError(e));
      }
      await widget.store.loadSecureConversation(accountId, widget.peerId);
      unawaited(_refreshPeerContact());
      _subscribeRealtime();
      _startPolling();
      // Initialize typing/presence indicator for 1:1 chats.
      // Skip in test environments. Sorted IDs keep both peers on the same
      // presence channel (presence:direct:<low>:<high>).
      if (!widget.testing) {
        final pair = [accountId, widget.peerId]..sort();
        _typingPresence = TypingPresence(
          client: widget.client,
          conversationId: 'direct:${pair[0]}:${pair[1]}',
          userId: accountId,
          displayName: widget.profile.name,
          onPresenceChange: (states) {
            if (mounted) setState(() {});
          },
        );
        _typingPresence!.join();
      }
      // Catch up immediately so an already-waiting envelope does not sit
      // until the first 30s tick.
      await _pollInbox();
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e is StateError ? e.message.toString() : 'Could not open this chat. Check your connection and reopen it.';
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

  Future<void> _ensureSession() =>
      _ensureSessionFor(widget.peerId, revalidate: true);

  String _peerIdentityPref(String peerId) =>
      'openchat.peerIdentity.v1.$accountId.$peerId';

  static bool _isUntrustedIdentity(Object e) =>
      e.toString().contains('UntrustedIdentity');

  /// Drops the local session (and optionally trusts a rotated peer
  /// identity) so the next ensure re-claims a fresh bundle. Used after
  /// repeated decrypt failures or trust errors — failed messages stay
  /// quarantined, new ones heal.
  Future<void> _resetPeerSession(
    String peerId, {
    String? trustIdentityKey,
  }) async {
    try {
      await channel.invokeMethod('signalDeleteSession', {
        'accountId': accountId,
        'peerId': peerId,
        'identityKey': ?trustIdentityKey,
      });
    } catch (_) {}
    try {
      if (trustIdentityKey != null) {
        await widget.store.preferences.setString(
          _peerIdentityPref(peerId),
          trustIdentityKey,
        );
      } else {
        await widget.store.preferences.remove(_peerIdentityPref(peerId));
      }
    } catch (_) {}
  }

  Future<void> _ensureSessionFor(
    String peerId, {
    bool revalidate = false,
  }) async {
    // Native returns {'hasSession': bool}, not a bare bool.
    final sessionState = await channel.invokeMapMethod('signalHasSession', {
      'accountId': accountId,
      'peerId': peerId,
    });
    final hasSession = sessionState?['hasSession'] == true;
    if (hasSession && !revalidate) return;
    // Server uses snake_case; the native bridge expects camelCase.
    Map<String, dynamic>? claimed;
    try {
      claimed = await widget.client.rpc(
        'claim_key_bundle',
        params: {'p_user_id': peerId},
      ) as Map<String, dynamic>;
    } catch (_) {
      // Offline on open: keep the existing session rather than breaking chat.
      if (hasSession) return;
      rethrow;
    }
    final identity = claimed['identity_key'] as String?;
    final known = widget.store.preferences.getString(_peerIdentityPref(peerId));
    if (hasSession && known != null && known == identity) return;
    if (hasSession || (known != null && known != identity)) {
      // Peer rotated identity (reinstall): drop the stale session and trust
      // the fresh key first, or processBundle/encrypt fail forever.
      await _resetPeerSession(peerId, trustIdentityKey: identity);
    }
    if (peerId == widget.peerId) {
      _peerIdentityKey = identity;
      if (mounted) setState(() {});
    }
    if (identity != null) {
      await widget.store.preferences.setString(
        _peerIdentityPref(peerId),
        identity,
      );
    }
    try {
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
    } catch (e) {
      if (!_isUntrustedIdentity(e)) rethrow;
      // Trust store disagrees (e.g. prefs wiped but native store kept):
      // reset trust explicitly and retry once.
      await _resetPeerSession(peerId, trustIdentityKey: identity);
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
      // A delivery receipt is created by the recipient, then updated when
      // read. Listen to both events so the first tick changes immediately.
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'envelope_receipts',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'sender_id',
          value: accountId,
        ),
        callback: (payload) => _onReceiptUpdate(payload.newRecord),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'envelope_receipts',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'sender_id',
          value: accountId,
        ),
        callback: (payload) => _onReceiptUpdate(payload.newRecord),
      )
      ..subscribe();
  }

  /// Handles real-time delivery/read receipt updates for our sent messages.
  Future<void> _onReceiptUpdate(Map<String, dynamic> record) async {
    if (!mounted) return;
    final clientId = record['client_message_id'] as String? ?? '';
    final status = record['read_at'] != null
        ? 'read'
        : record['delivered_at'] != null
        ? 'delivered'
        : 'sent';
    if (clientId.isEmpty) return;
    await widget.store.updateSecureStatus(
      accountId,
      widget.peerId,
      clientId,
      status,
      deliveredAt: record['delivered_at'] as String?,
      readAt: record['read_at'] as String?,
    );
    if (mounted) setState(() {});
  }

  /// Maximum failed decrypts before a poison envelope is quarantined as a
  /// visible placeholder (and only then acknowledged).
  static const _maxEnvelopeFailures = 5;

  Future<void> _onEnvelope(Map<String, dynamic> record) {
    // Realtime and polling can deliver the same Signal packet concurrently.
    // Serialize decryption as well as storage so the ratchet advances once.
    _receiveQueue = _receiveQueue
        .catchError((_) {})
        .then((_) => _receiveEnvelope(record));
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
        final decrypted = await channel.invokeMethod('signalDecrypt', {
          'accountId': accountId,
          'peerId': sender,
          'type': candidate.key,
          'body': candidate.value,
        }) as Map<dynamic, dynamic>;
        plainText = utf8.decode(base64Decode(decrypted['plain'] as String));
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
        // Likely cause is a stale session (peer reinstalled and rotated
        // identity). Drop it so the next open/send re-claims a fresh bundle;
        // this message itself is unrecoverable — ask them to send it again.
        await _resetPeerSession(sender);
        try {
          await widget.store.addSecureMessage(
            accountId,
            sender,
            '⚠️ A message arrived but could not be decrypted. Ask them to send it again.',
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
    if (!_accessGranted ||
        _reading ||
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
      const Duration(seconds: 20),
      (_) => _pollInbox(),
    );
    _tickTimer = Timer.periodic(
      const Duration(seconds: 5),
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
      final ids = List.generate(
        min(50, pending.length),
        (i) => pending[(start + i) % pending.length].clientId,
      );
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
    final edit = _editing;
    final bool sent;
    if (edit != null) {
      sent = await _transmit(encodeEditBody(edit.ref, text));
    } else if (reply != null) {
      sent = await _transmit(
        encodeReplyBody(reply.ref, text, reply.name, reply.quote),
      );
    } else {
      sent = await _transmit(encodeTextBody(text));
    }
    if (sent) HapticFeedback.lightImpact();
    if (mounted) {
      setState(() {
        _sendingText = false;
        if (sent && composer.text.trim() == text) {
          composer.clear();
          // The listener persists the clear, dropping the draft flag.
          if (_replyTo == reply) _replyTo = null;
          if (_editing == edit) _editing = null;
        }
      });
      // Corrections are not new arrivals; only fresh text/replies poke.
      if (sent && edit == null) {
        unawaited(
          NotifyService.poke(
            widget.client,
            kind: 'message',
            peer: widget.peerId,
          ),
        );
      }
    }
  }

  /// User-safe media errors: raw platform exceptions never reach the UI.
  static String _friendlyMediaError(String action, Object e) {
    if (_isUntrustedIdentity(e)) {
      return 'Peer security code changed. Reopening this chat refreshes encryption — then send again.';
    }
    if (e is StateError) return e.message.toString();
    return '$action failed. Check your connection and storage allowance.';
  }

  /// User-safe send errors: raw platform/protocol exceptions never reach
  /// the UI. StateErrors are already friendly by construction.
  static String _friendlySendError(Object e) {
    if (e is StateError) return e.message.toString();
    if (_isUntrustedIdentity(e)) {
      return 'Peer security code changed. Reopening this chat refreshes encryption — then send again.';
    }
    return 'Message could not be sent. Check your connection and try again.';
  }

  /// Encrypts [plainText] (raw text or an encoded body), enqueues it for
  /// [toPeer] (this chat's peer by default), and stores the local copy.
  /// Shared by text, media, polls, votes, and forwarded content.
  Future<bool> _transmit(
    String plainText, {
    String? toPeer,
    bool retriedSession = false,
  }) async {
    final peerId = toPeer ?? widget.peerId;
    try {
      final random = Random.secure();
      final localId = base64UrlEncode(
        List<int>.generate(24, (_) => random.nextInt(256)),
      );
      await _ensureSessionFor(peerId);
      final result = await channel.invokeMethod('signalEncrypt', {
        'accountId': accountId,
        'peerId': peerId,
        'plain': base64Encode(utf8.encode(plainText)),
      }) as Map<dynamic, dynamic>;
      // Prefix the Signal message type; the envelope has no type column.
      final queued = await widget.client.rpc(
        'enqueue_message',
        params: {
          'p_recipient_id': peerId,
          'p_client_message_id': localId,
          'p_ciphertext': EnvelopeCodec.encode(
            result['type'] as int,
            result['body'] as String,
          ),
        },
      ) as Map<String, dynamic>;
      switch (queued['status']) {
        case 'sent':
        case 'duplicate':
          await widget.store.addSecureMessage(
            accountId,
            peerId,
            plainText,
            mine: true,
            clientId: localId,
            at:
                DateTime.tryParse(queued['created_at'] as String? ?? '') ??
                DateTime.tryParse(queued['expires_at'] as String? ?? '')
                    ?.subtract(const Duration(days: 7)),
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
          throw StateError(
            'Contact unavailable. They may have blocked you or removed the connection.',
          );
        default:
          throw StateError('Message rejected by the server.');
      }
    } catch (e) {
      if (!retriedSession && _isUntrustedIdentity(e)) {
        // Stale session (peer reinstalled): heal transparently and retry once.
        await _resetPeerSession(peerId);
        try {
          await _ensureSessionFor(peerId, revalidate: true);
        } catch (_) {}
        return _transmit(plainText, toPeer: toPeer, retriedSession: true);
      }
      if (mounted) {
        setState(() => _error = _friendlySendError(e));
      }
      return false;
    }
  }

  Future<void> _pickAndSendImage() async {
    if (_sendingMedia) return;
    // Gallery/camera leave the activity (pause/resume): not a real background.
    AppLock.suppressRelockOnce = true;
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
              _AttachTile(
                icon: Icons.mic,
                color: const Color(0xFF8E24AA),
                label: 'Voice',
                onTap: () => Navigator.pop(ctx, 'voice_record'),
              ),
              _AttachTile(
                icon: Icons.description_outlined,
                color: const Color(0xFF546E7A),
                label: 'Document',
                onTap: () => Navigator.pop(ctx, 'document'),
              ),
              _AttachTile(
                icon: Icons.person_outline,
                color: const Color(0xFF009EE6),
                label: 'Contact',
                onTap: () => Navigator.pop(ctx, 'contact'),
              ),
              _AttachTile(
                icon: Icons.location_on_outlined,
                color: const Color(0xFF0F9D58),
                label: 'Location',
                onTap: () => Navigator.pop(ctx, 'location'),
              ),
              _AttachTile(
                icon: Icons.filter_1_outlined,
                color: const Color(0xFF00897B),
                label: 'Once photo',
                onTap: () => Navigator.pop(ctx, 'once_photo'),
              ),
              _AttachTile(
                icon: Icons.filter_1,
                color: const Color(0xFF00897B),
                label: 'Once video',
                onTap: () => Navigator.pop(ctx, 'once_video'),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'once_video') {
      await _pickAndSendVideo(false, viewOnce: true);
      return;
    }
    if (choice == 'document') {
      await _pickDocument();
      return;
    }
    if (choice == 'contact') {
      await _pickAndSendContact();
      return;
    }
    if (choice == 'location') {
      await _pickAndSendLocation();
      return;
    }
    if (choice == 'voice_record') {
      await _recordAndSendVoice();
      return;
    }
    if (choice.startsWith('video_')) {
      await _pickAndSendVideo(choice == 'video_camera');
      return;
    }
    XFile? picked;
    try {
      picked = choice == 'photo_gallery' || choice == 'once_photo'
          ? await media.pickGalleryImage()
          : await media.pickCameraImage();
    } on Exception {
      if (mounted) setState(() => _error = 'Could not open your gallery.');
      return;
    }
    if (picked == null || !mounted) return;
    final caption = TextEditingController();
    final send = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          choice == 'once_photo' ? 'Send view-once photo' : 'Send image',
        ),
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
      final sealed = await media.uploadSealed(File(picked.path), widget.peerId);
      final sent = await _transmit(
        encodeImageBody(
          sealed.path,
          caption.text.trim(),
          key: sealed.key,
          nonce: sealed.nonce,
          viewOnce: choice == 'once_photo',
        ),
      );
      if (sent && mounted) {
        unawaited(
          NotifyService.poke(
            widget.client,
            kind: 'message',
            peer: widget.peerId,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = _friendlyMediaError('Image upload', e));
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
                    onPressed: () =>
                        setDialog(() => options.add(TextEditingController())),
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
    final sent = await _transmit(encodePollBody(pollId, q, opts, multi: multi));
    if (sent && mounted) {
      unawaited(
        NotifyService.poke(widget.client, kind: 'message', peer: widget.peerId),
      );
    }
  }

  Future<void> _pickAndSendVideo(
    bool fromCamera, {
    bool viewOnce = false,
  }) async {
    if (_sendingMedia) return;
    AppLock.suppressRelockOnce = true;
    XFile? picked;
    try {
      picked = fromCamera
          ? await media.pickCameraVideo()
          : await media.pickGalleryVideo();
    } on Exception {
      if (mounted) setState(() => _error = 'Could not open your videos.');
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
        title: Text(viewOnce ? 'Send view-once video' : 'Send video'),
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
      final sent = await _transmit(
        encodeVideoBody(
          sealed.path,
          caption.text.trim(),
          key: sealed.key,
          nonce: sealed.nonce,
          thumbPath: sealed.thumbPath.isEmpty ? null : sealed.thumbPath,
          thumbKey: sealed.thumbKey.isEmpty ? null : sealed.thumbKey,
          thumbNonce: sealed.thumbNonce.isEmpty ? null : sealed.thumbNonce,
          durationSec: durationSec,
          viewOnce: viewOnce,
        ),
      );
      if (sent && mounted) {
        unawaited(
          NotifyService.poke(
            widget.client,
            kind: 'message',
            peer: widget.peerId,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = _friendlyMediaError('Video upload', e));
      }
    } finally {
      if (mounted) setState(() => _sendingMedia = false);
    }
  }

  Future<void> _pickDocument() async {
    if (_sendingMedia) return;
    AppLock.suppressRelockOnce = true;
    final selected = await FilePicker.platform.pickFiles(withData: false);
    if (!mounted || selected == null || selected.files.single.path == null)
      return;
    final picked = selected.files.single;
    if (picked.size > DocumentTransfer.maxBytes) {
      setState(() => _error = 'Documents must be 200 MB or smaller.');
      return;
    }
    try {
      final usage =
          await widget.client.rpc('chat_media_usage') as Map<String, dynamic>?;
      final used = (usage?['bytes'] as num?)?.toInt() ?? 0;
      if (used + picked.size > 300 * 1024 * 1024) {
        if (mounted) {
          setState(
            () => _error = 'Storage budget exhausted. Delete old media or documents and try again.',
          );
        }
        return;
      }
    } catch (_) {
      // Usage check is advisory; the server enforces the real quota.
    }
    setState(() {
      _sendingMedia = true;
      _error = null;
      _documentControl = TransferControl();
      _documentProgress = 0;
    });
    try {
      final encoded = await documents.upload(
        File(picked.path!),
        widget.peerId,
        name: picked.name,
        control: _documentControl,
        onProgress: (p) {
          if (mounted) setState(() => _documentProgress = p);
        },
      );
      if (await _transmit(encoded))
        unawaited(
          NotifyService.poke(
            widget.client,
            kind: 'message',
            peer: widget.peerId,
          ),
        );
    } on TransferCancelled {
      // User cancelled the upload; partial chunks are cleaned up in upload().
    } catch (e) {
      if (mounted) {
        final message = e.toString();
        setState(
          () => _error = message.contains('Storage budget exhausted')
              ? 'Storage budget exhausted. Delete old media or documents and try again.'
              : message.contains('single-object limit')
              ? 'That file exceeds the 64 MB single-object limit.'
              : 'Document upload failed. Check your connection and storage allowance.',
        );
      }
    } finally {
      if (mounted)
        setState(() {
          _sendingMedia = false;
          _documentControl = null;
        });
    }
  }

  Future<void> _pickAndSendContact() async {
    if (_sendingMedia) return;
    setState(() => _error = null);
    List<device_contacts.Contact> deviceContacts;
    try {
      final status = await device_contacts.FlutterContacts.permissions.request(
        device_contacts.PermissionType.read,
      );
      if (status != device_contacts.PermissionStatus.granted) {
        throw StateError('Contacts permission is required to share.');
      }
      deviceContacts = await device_contacts.FlutterContacts.getAll(
        properties: {
          device_contacts.ContactProperty.name,
          device_contacts.ContactProperty.phone,
        },
      );
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is StateError
              ? e.message.toString()
              : 'Could not read your contacts.',
        );
      }
      return;
    }
    deviceContacts.removeWhere((c) => c.phones.isEmpty);
    if (!mounted) return;
    final picked = await showModalBottomSheet<device_contacts.Contact>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Share contact',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: deviceContacts.length,
                itemBuilder: (ctx, i) {
                  final c = deviceContacts[i];
                  final name = c.displayName ?? '';
                  return ListTile(
                    leading: CircleAvatar(
                      child: Text(name.isEmpty ? '?' : name[0].toUpperCase()),
                    ),
                    title: Text(name.isEmpty ? 'Unnamed contact' : name),
                    subtitle: Text(c.phones.first.number),
                    onTap: () => Navigator.pop(ctx, c),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final pickedName = picked.displayName ?? '';
    final name = pickedName.isEmpty ? 'Shared contact' : pickedName;
    final phones = picked.phones.map((p) => p.number).take(5).toList();
    if (await _transmit(encodeContactBody(name, phones))) {
      unawaited(
        NotifyService.poke(widget.client, kind: 'message', peer: widget.peerId),
      );
    }
  }

  Future<void> _pickAndSendLocation() async {
    if (_sendingMedia) return;
    setState(() {
      _sendingMedia = true;
      _error = null;
    });
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw StateError('Location permission is required to share.');
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
        ),
      ).timeout(const Duration(seconds: 20));
      if (!mounted) return;
      
      // Show options: static location or live location
      final choice = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.location_on),
                title: const Text('Send current location'),
                subtitle: Text(
                  '${position.latitude.toStringAsFixed(5)}, ${position.longitude.toStringAsFixed(5)}',
                ),
                onTap: () => Navigator.pop(ctx, 'static'),
              ),
              ListTile(
                leading: const Icon(Icons.location_on, color: Color(0xFF00A884)),
                title: const Text('Share live location'),
                subtitle: const Text('Share your real-time location'),
                onTap: () => Navigator.pop(ctx, 'live'),
              ),
            ],
          ),
        ),
      );
      
      if (choice == 'static') {
        final labelController = TextEditingController();
        final label = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Share location'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${position.latitude.toStringAsFixed(5)}, ${position.longitude.toStringAsFixed(5)}',
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: labelController,
                  decoration: const InputDecoration(
                    labelText: 'Label (optional)',
                    hintText: 'e.g. Home',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, labelController.text.trim()),
                child: const Text('Send'),
              ),
            ],
          ),
        );
        labelController.dispose();
        if (label == null || !mounted) return;
        if (await _transmit(
          encodeLocationBody(
            position.latitude,
            position.longitude,
            label: label.isEmpty ? null : label,
          ),
        )) {
          unawaited(
            NotifyService.poke(
              widget.client,
              kind: 'message',
              peer: widget.peerId,
            ),
          );
        }
      } else if (choice == 'live') {
        await _startLiveLocation(position.latitude, position.longitude);
      }
    } on TimeoutException {
      if (mounted) setState(() => _error = 'Location request timed out.');
    } on StateError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not get location.');
    } finally {
      if (mounted) setState(() => _sendingMedia = false);
    }
  }

  /// Shares live location for a specified duration.
  Future<void> _startLiveLocation(double initialLat, double initialLng) async {
    if (!mounted) return;
    final duration = await showModalBottomSheet<Duration>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Share live location for',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.timer),
              title: const Text('15 minutes'),
              onTap: () => Navigator.pop(ctx, const Duration(minutes: 15)),
            ),
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: const Text('1 hour'),
              onTap: () => Navigator.pop(ctx, const Duration(hours: 1)),
            ),
            ListTile(
              leading: const Icon(Icons.timer_3_outlined),
              title: const Text('8 hours'),
              onTap: () => Navigator.pop(ctx, const Duration(hours: 8)),
            ),
          ],
        ),
      ),
    );
    
    if (duration == null || !mounted) return;
    
    // Send initial live location message
    if (!await _transmit(
      encodeLocationBody(
        initialLat,
        initialLng,
        label: 'Live location',
        fwd: false,
      ),
    )) {
      if (mounted) setState(() => _error = 'Failed to start live location.');
      return;
    }
    
    // Start periodic location updates
    Timer.periodic(const Duration(seconds: 30), (timer) async {
      if (!mounted || timer.tick * 30 >= duration.inSeconds) {
        timer.cancel();
        // Send stop message
        await _transmit(encodeTextBody('📍 Live location sharing ended.'));
        return;
      }
      
      try {
        var permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied ||
            permission == LocationPermission.deniedForever) {
          timer.cancel();
          return;
        }
        final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.medium,
          ),
        ).timeout(const Duration(seconds: 10));
        
        // Send location update as a new message (in a real implementation,
        // this would update the existing live location bubble)
        await _transmit(
          encodeLocationBody(
            position.latitude,
            position.longitude,
            label: 'Live location update',
          ),
        );
      } catch (_) {
        // Ignore individual update failures
      }
    });
  }

  Future<void> _recordAndSendVoice() async {
    final recorder = VoiceNoteRecorder(
      maxDuration: const Duration(minutes: 2),
      onRecordingStateChanged: (recording) {
        if (recording) {
          _typingPresence?.startRecording();
        } else {
          _typingPresence?.stopRecording();
        }
        if (mounted) setState(() {});
      },
      onRecorded: (file, duration, waveform) async {
        if (!mounted) return;
        setState(() {
          _sendingMedia = true;
          _error = null;
        });
        try {
          final sealed = await media.uploadSealed(file, widget.peerId);
          final sent = await _transmit(
            encodeVoiceBody(
              sealed.path,
              duration.inSeconds,
              key: sealed.key,
              nonce: sealed.nonce,
              waveform: waveform,
            ),
          );
          if (!sent) throw StateError('Voice note not sent');
          if (mounted) {
            unawaited(
              NotifyService.poke(
                widget.client,
                kind: 'message',
                peer: widget.peerId,
              ),
            );
          }
        } catch (e) {
          if (mounted)
            setState(() => _error = _friendlyMediaError('Voice note', e));
          rethrow;
        } finally {
          if (mounted) setState(() => _sendingMedia = false);
        }
      },
    );
    if (mounted) {
      // Show the recorder as a modal bottom sheet
      await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (ctx) => recorder,
      );
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
              fallback:
                  'No session yet — open the chat online to fetch their key.',
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
                            if (sheetContext.mounted) {
                              Navigator.pop(sheetContext);
                            }
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

  /// Lowercased searchable text for in-chat search: bodies, captions,
  /// poll questions, quotes. Control rows never match.
  String _searchText(SecureMessage msg) {
    final body = parseMessageBody(msg.text);
    if (body.isVote || body.isDelete || body.isReact || body.isEdit) return '';
    if (body.isPoll) {
      return '${body.question ?? ''} ${(body.options ?? []).join(' ')}'
          .toLowerCase();
    }
    if (body.isTombstone) return 'deleted message';
    return '${body.text} ${body.quoteText ?? ''}'.toLowerCase();
  }

  String _quoteSummary(MediaBody body) {
    if (body.isVoice) return 'Voice note (${body.durationSec}s)';
    if (body.isContact) return 'Contact: ${body.contactName}';
    if (body.isLocation) {
      return body.text.isNotEmpty
          ? 'Location: ${body.text}'
          : 'Shared location';
    }
    if (body.isDocument) return body.fileName;
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
    setState(
      () => _replyTo = (
        ref: msg.ref,
        name: msg.mine
            ? (widget.profile.name.isEmpty ? 'Sender' : widget.profile.name)
            : widget.peerName,
        quote: _quoteSummary(body),
      ),
    );
  }

  /// WhatsApp-style long-press menu for one message.
  Future<void> _messageActions(SecureMessage msg) async {
    final body = parseMessageBody(msg.text);
    if (body.isTombstone) return;
    if (body.viewOnce) {
      final remove = await showModalBottomSheet<bool>(
        context: context,
        builder: (ctx) => SafeArea(
          child: ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Delete for me'),
            onTap: () => Navigator.pop(ctx, true),
          ),
        ),
      );
      if (remove == true)
        await widget.store.removeSecureMessage(
          accountId,
          widget.peerId,
          msg.ref,
        );
      return;
    }
    final stars = await widget.store.secureStars(accountId, widget.peerId);
    final pins = await widget.store.securePins(accountId, widget.peerId);
    if (!mounted) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!body.isVote && !body.isDelete)
                ListTile(
                  leading: const Icon(Icons.reply_outlined),
                  title: const Text('Reply'),
                  onTap: () => Navigator.pop(ctx, 'reply'),
                ),
              if (!body.isVote &&
                  !body.isDelete &&
                  !body.isReact &&
                  !body.isEdit)
                ListTile(
                  leading: const Icon(Icons.emoji_emotions_outlined),
                  title: const Text('React'),
                  onTap: () => Navigator.pop(ctx, 'react'),
                ),
              if (body.text.isNotEmpty || body.question != null)
                ListTile(
                  leading: const Icon(Icons.copy_outlined),
                  title: const Text('Copy'),
                  onTap: () => Navigator.pop(ctx, 'copy'),
                ),
              if (msg.canEdit(DateTime.now()))
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: const Text('Edit'),
                  subtitle: const Text('Within 15 minutes of sending'),
                  onTap: () => Navigator.pop(ctx, 'edit'),
                ),
              ListTile(
                leading: const Icon(Icons.forward_outlined),
                title: const Text('Forward'),
                onTap: () => Navigator.pop(ctx, 'forward'),
              ),
              ListTile(
                leading: Icon(
                  stars.contains(msg.ref) ? Icons.star : Icons.star_outline,
                ),
                title: Text(stars.contains(msg.ref) ? 'Unstar' : 'Star'),
                onTap: () => Navigator.pop(ctx, 'star'),
              ),
              ListTile(
                leading: const Icon(Icons.push_pin_outlined),
                title: Text(pins.contains(msg.ref) ? 'Unpin' : 'Pin'),
                onTap: () => Navigator.pop(ctx, 'pin'),
              ),
              if (msg.mine)
                ListTile(
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
          ),
        ),
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
                  : (body.text.isNotEmpty ? body.text : _quoteSummary(body)));
        await Clipboard.setData(ClipboardData(text: copyText));
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
        }
      case 'react':
        await _fullEmojiKeyboard(msg);
case 'edit':
        if (!msg.canEdit(DateTime.now())) {
          if (mounted) {
            setState(() => _error = 'The 15-minute edit window has ended.');
          }
          break;
        }
        final newText = await showDialog<String>(
          context: context,
          builder: (ctx) {
            final controller = TextEditingController(text: body.text);
            return AlertDialog(
              title: const Text('Edit Message'),
              content: TextField(
                controller: controller,
                maxLength: 4000,
                decoration: const InputDecoration(hintText: 'Edit your message'),
                autofocus: true,
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, controller.text.trim()),
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
        if (newText != null && newText.isNotEmpty && newText != body.text) {
          await widget.store.editSecureMessage(
            accountId,
            widget.peerId,
            msg.ref,
            newText,
            channel,
          );
        }
        break;
        await _forwardPicker(body);
      case 'star':
        await widget.store.toggleSecureStar(accountId, widget.peerId, msg.ref);
        final starred = (await widget.store.secureStars(
          accountId,
          widget.peerId,
        )).contains(msg.ref);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(starred ? 'Starred.' : 'Unstarred.')),
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
        final original = msg.text;
        final ref = msg.ref;
        await widget.store.removeSecureMessage(
          accountId,
          widget.peerId,
          ref,
        );
        if (mounted) setState(() {});
        _refreshPins();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Deleted for me'),
              duration: const Duration(seconds: 5),
              action: SnackBarAction(
                label: 'Undo',
                onPressed: () async {
                  await widget.store.restoreSecureMessage(
                    accountId,
                    widget.peerId,
                    ref,
                    original,
                  );
                  if (mounted) setState(() {});
                  _refreshPins();
                },
              ),
            ),
          );
        }
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
            if (mounted) {
              setState(
                () => _error = 'The 60-hour deletion window has ended.',
              );
            }
            break;
          }
          await widget.store.deleteSecureMessage(
            accountId,
            widget.peerId,
            msg.ref,
            forEveryone: true,
            channel: channel,
          );
        }
        break;
    }
  }

  /// Contact picker for forwarding into another encrypted chat.
  Future<void> _forwardPicker(MediaBody body) async {
    List<CloudContact> contacts = [];
    try {
      contacts = (await SupabaseContactsRepository(
        widget.client,
      ).contacts()).where((c) => c.status == 'accepted').toList();
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Contacts could not be loaded. Try again.');
      }
      return;
    }
    if (!mounted) return;
    final target = await showModalBottomSheet<CloudContact>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
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
                    foregroundImage:
                        (c.avatarUrl != null && c.avatarUrl!.isNotEmpty)
                        ? NetworkImage(c.avatarUrl!)
                        : null,
                    child: Text(c.name.isEmpty ? '?' : c.name[0].toUpperCase()),
                  ),
                  title: Text(c.name),
                  subtitle: Text('@${c.username}'),
                  onTap: () => Navigator.pop(ctx, c),
                ),
            ],
          ),
        ),
      ),
    );
    if (target == null || !mounted) return;
    setState(() => _error = null);
    try {
      String forwarded;
      if (body.isDocument) {
        final dir = await (await getTemporaryDirectory()).createTemp(
          'oc-forward-',
        );
        try {
          final file = await documents.download(
            body,
            File('${dir.path}/document'),
          );
          forwarded = await documents.upload(
            file,
            target.userId,
            name: body.fileName,
            forwarded: true,
          );
        } finally {
          await dir.delete(recursive: true);
        }
      } else {
        forwarded = await media.forwardBody(body, target.userId);
      }
      final sent = await _transmit(forwarded, toPeer: target.userId);
      if (sent && mounted) {
        unawaited(
          NotifyService.poke(
            widget.client,
            kind: 'message',
            peer: target.userId,
          ),
        );
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Forwarded to ${target.name}.')));
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = 'The message could not be forwarded. Try again.',
        );
      }
    }
  }

  void _hideReactBar() {
    _reactBar?.remove();
    _reactBar = null;
  }

  void _onScroll() {
    _hideReactBar();
    if (!scroll.hasClients) return;
    final show = scroll.offset > 300;
    if (show != _showJump && mounted) setState(() => _showJump = show);
  }

  /// WhatsApp-style quick reactions: a floating bar with the 6 standard
  /// emojis plus a "+" that opens the full emoji keyboard. One tap sends.
  static const _barEmojis = ['❤️', '😂', '😮', '😢', '🙏', '👍'];

  void _showReactBar(SecureMessage msg) {
    _hideReactBar();
    final votes =
        widget.store.secureReactions(accountId, widget.peerId)[msg.ref] ?? {};
    final mq = MediaQuery.of(context);
    const barWidth = 336.0;
    const barHeight = 60.0;
    final anchor = _tapPos ?? Offset(mq.size.width / 2, mq.size.height / 3);
    // Bar floats above the tap; clamped so it never leaves the screen.
    final left = (anchor.dx - barWidth / 2).clamp(
      8.0,
      (mq.size.width - barWidth - 8).clamp(8.0, double.infinity),
    );
    final top = (anchor.dy - barHeight - 72).clamp(
      mq.padding.top + 64.0,
      (mq.size.height - barHeight - 160).clamp(
        mq.padding.top + 64.0,
        double.infinity,
      ),
    );
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _hideReactBar,
              child: const SizedBox.expand(),
            ),
          ),
          Positioned(
            left: left,
            top: top,
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(30),
              color: Theme.of(ctx).colorScheme.surfaceContainerHigh,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final e in _barEmojis)
                      GestureDetector(
                        onTap: () {
                          final side = votes[e];
                          _hideReactBar();
                          _toggleReaction(
                            msg,
                            e,
                            side == 'mine' || side == 'both',
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5),
                          decoration: (votes[e] == 'mine' || votes[e] == 'both')
                              ? BoxDecoration(
                                  color: Theme.of(ctx)
                                      .colorScheme
                                      .primaryContainer,
                                  borderRadius: BorderRadius.circular(20),
                                )
                              : null,
                          child: Text(e, style: const TextStyle(fontSize: 30)),
                        ),
                      ),
                    GestureDetector(
                      onTap: () {
                        _hideReactBar();
                        _fullEmojiKeyboard(msg);
                      },
                      child: Container(
                        margin: const EdgeInsets.only(left: 2),
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Theme.of(ctx)
                              .colorScheme
                              .surfaceContainerHighest,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.add,
                          size: 22,
                          color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
    _reactBar = entry;
    Overlay.of(context).insert(entry);
  }

  /// Full emoji keyboard for reactions (the "+" path and the menu's React).
  Future<void> _fullEmojiKeyboard(SecureMessage msg) async {
    final votes =
        widget.store.secureReactions(accountId, widget.peerId)[msg.ref] ?? {};
    final emoji = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.55,
          child: EmojiPicker(
            onEmojiSelected: (category, e) => Navigator.pop(ctx, e.emoji),
            config: Config(
              categoryViewConfig: const CategoryViewConfig(
                initCategory: Category.SMILEYS,
                recentTabBehavior: RecentTabBehavior.NONE,
              ),
            ),
          ),
        ),
      ),
    );
    if (emoji == null || emoji.isEmpty || !mounted) return;
    final side = votes[emoji];
    await _toggleReaction(msg, emoji, side == 'mine' || side == 'both');
  }

  /// Sends explicit set/remove reaction state with an optimistic local
  /// apply; a failed send reverts so the UI never lies.
  Future<void> _toggleReaction(
    SecureMessage msg,
    String emoji,
    bool mineNow,
  ) async {
    HapticFeedback.selectionClick();
    final id = msg.mine ? msg.clientId : msg.peerClientId;
    if (id == null || id.isEmpty) {
      if (mounted) {
        setState(
          () =>
              _error = 'This older message has no shared reaction identifier.',
        );
      }
      return;
    }
    // Apply locally first for instant feedback
    await widget.store.applySecureReaction(
      accountId,
      widget.peerId,
      msg.ref,
      emoji,
      mine: true,
      remove: mineNow,
    );
    // Send to peer
    final sent = await _transmit(
      encodeReactBody(
        '${msg.mine ? accountId : widget.peerId}:$id',
        emoji,
        remove: mineNow,
      ),
    );
    // Revert the optimistic apply when nothing left the device. Unknown
    // legacy rows have no sender key and cannot be targeted remotely.
    if (!sent && mounted) {
      setState(() => _error = 'Reaction failed. Check your connection.');
      // Revert local reaction
      await widget.store.applySecureReaction(
        accountId,
        widget.peerId,
        msg.ref,
        emoji,
        mine: true,
        remove: !mineNow,
      );
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
              _InfoRow(icon: Icons.check, label: 'Sent', value: sent),
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
    final stars = await widget.store.secureStars(accountId, widget.peerId);
    if (!mounted) return;
    final messages = widget.store.getSecureConversation(
      accountId,
      widget.peerId,
    );
    final starred = messages.where((m) => stars.contains(m.ref)).toList();
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
                    leading: const Icon(Icons.push_pin_outlined, size: 18),
                    title: Text(
                      _quoteSummary(parseMessageBody(lookup(ref)?.text ?? '')),
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

  /// Explains why delivery/calls/profile/status may not work for this
  /// peer, with one-tap invite/accept. Hidden once connected.
  Widget _connectionBanner() {
    final c = _peerContact;
    final String text;
    final String? actionLabel;
    final Future<void> Function()? action;
    if (c == null) {
      text =
          'Not connected yet. Messages, calls, profile and status need an accepted contact.';
      actionLabel = widget.peerUsername.isEmpty ? null : 'Send invite';
      action = widget.peerUsername.isEmpty ? null : _invitePeer;
    } else if (c.status == 'blocked') {
      text = 'This contact is blocked. Unblock in People to resume.';
      actionLabel = null;
      action = null;
    } else if (c.status == 'pending' && c.incoming) {
      text = '${widget.peerName} invited you. Accept to enable messages and calls.';
      actionLabel = 'Accept';
      action = _acceptPeerInvite;
    } else if (c.status == 'pending') {
      text = 'Invite sent. Waiting for ${widget.peerName} to accept.';
      actionLabel = null;
      action = null;
    } else {
      return const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.person_add_outlined, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 12))),
          if (actionLabel != null)
            TextButton(
              onPressed: _contactBusy ? null : action,
              child: Text(actionLabel),
            ),
        ],
      ),
    );
  }

  String _toneKey() => 'openchat.tone.v1.$accountId.${widget.peerId}';

  String _currentTone() =>
      widget.store.preferences.getString(_toneKey()) ?? 'Default';

  Future<void> _pickTone() async {
    const tones = ['Default', 'Silent', 'Chime', 'Bell'];
    final current = _currentTone();
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Notification tone'),
        children: [
          for (final t in tones)
            ListTile(
              leading: Icon(
                t == current
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
              ),
              title: Text(t),
              onTap: () => Navigator.pop(ctx, t),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    await widget.store.preferences.setString(_toneKey(), picked);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Tone set to $picked for this chat.')),
      );
    }
  }

  Future<void> _showStorage() async {
    final msgs = widget.store.getSecureConversation(accountId, widget.peerId);
    var textBytes = 0;
    final counts = <String, int>{
      'text': 0,
      'photo': 0,
      'video': 0,
      'audio': 0,
      'doc': 0,
    };
    for (final m in msgs) {
      if (m.hidden) continue;
      final b = parseMessageBody(m.text);
      if (b.isTombstone || b.isVote || b.isDelete || b.isReact || b.isEdit) {
        continue;
      }
      textBytes += m.text.length;
      if (b.isImage) {
        counts['photo'] = counts['photo']! + 1;
      } else if (b.isVideo) {
        counts['video'] = counts['video']! + 1;
      } else if (b.isVoice) {
        counts['audio'] = counts['audio']! + 1;
      } else if (b.isDocument) {
        counts['doc'] = counts['doc']! + 1;
      } else {
        counts['text'] = counts['text']! + 1;
      }
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Storage • ${widget.peerName}'),
        content: Text(
          '${msgs.length} messages stored\n'
          'Text ${counts['text']}, Photos ${counts['photo']}, '
          'Videos ${counts['video']}, Audio ${counts['audio']}, '
          'Docs ${counts['doc']}\n'
          'Approx text ${(textBytes / 1024).toStringAsFixed(1)} KB '
          '(media files excluded).',
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

  Future<void> _exportChat() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final msgs = widget.store.getSecureConversation(accountId, widget.peerId);
      final buf = StringBuffer()
        ..writeln('OpenChat export with ${widget.peerName}')
        ..writeln('Exported ${DateTime.now().toLocal()}')
        ..writeln('---');
      for (final m in msgs) {
        if (m.hidden) continue;
        final b = parseMessageBody(m.text);
        if (b.isVote || b.isDelete || b.isReact || b.isEdit) continue;
        final who = m.mine ? 'Me' : widget.peerName;
        final summary = b.isTombstone
            ? 'This message was deleted'
            : _quoteSummary(b);
        buf.writeln(
          '[${m.at.toLocal().toString().split('.').first}] $who: $summary',
        );
      }
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/openchat_${widget.peerId}_${DateTime.now().millisecondsSinceEpoch}.txt',
      );
      await file.writeAsString(buf.toString());
      await OpenFilex.open(file.path);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _documentControl?.cancelled = true;
    _hideReactBar();
    composer.removeListener(_saveDraft);
    scroll.removeListener(_onScroll);
    // Persist the draft even if the listener missed the last keystroke.
    widget.store.setSecureDraft(accountId, widget.peerId, composer.text);
    NotifyService.instance.openChats.remove(widget.peerId);
    _realtime?.unsubscribe();
    _pollTimer?.cancel();
    _tickTimer?.cancel();
    _typingPresence?.dispose();
    composer.dispose();
    searchBox.dispose();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_accessGranted) {
      return Scaffold(
        appBar: AppBar(title: const Text('Locked chat')),
        body: Center(
          child: FilledButton.icon(
            onPressed: _unlockChat,
            icon: const Icon(Icons.lock),
            label: const Text('Unlock with chat PIN'),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: searchBox,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search in conversation…',
                  border: InputBorder.none,
                ),
                onChanged: (v) =>
                    setState(() => _searchQuery = v.trim().toLowerCase()),
              )
            : Row(
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: const Color(0xFFE4EBFF),
                    foregroundImage:
                        (widget.peerAvatarUrl != null &&
                            widget.peerAvatarUrl!.isNotEmpty)
                        ? NetworkImage(widget.peerAvatarUrl!)
                        : null,
                    child: Text(
                      widget.peerName.isEmpty
                          ? '?'
                          : widget.peerName[0].toUpperCase(),
                      style: const TextStyle(
                        color: Color(0xFF245CDB),
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(widget.peerName, overflow: TextOverflow.ellipsis),
                        if (_typingPresence != null)
                          Builder(
                            builder: (context) {
                              final t = _typingPresence!.peerOnlineText ??
                                  (_typingPresence!.statusText ?? '');
                              if (t.isEmpty) return const SizedBox.shrink();
                              final active = t.contains('typing') ||
                                  t.contains('recording');
                              return Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (active)
                                    const TypingDots()
                                  else
                                    Flexible(
                                      child: Text(
                                        t,
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.normal,
                                          color: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.color,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  if (active)
                                    Flexible(
                                      child: Text(
                                        ' $t',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.normal,
                                          color: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.color,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                ],
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                ],
              ),

        actions: [
          IconButton(
            tooltip: _searching ? 'Close search' : 'Search in conversation',
            onPressed: () => setState(() {
              _searching = !_searching;
              _searchQuery = '';
              _searchDate = null;
              _searchMedia = null;
              searchBox.clear();
            }),
            icon: Icon(_searching ? Icons.close : Icons.search),
          ),
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
                case 'lock':
                  final wasLocked =
                      widget.store.preferences.getBool(_lockKey) == true;
                  final hasPin = await ChatLock.hasPin();
                  if (!context.mounted) return;
                  final ok = hasPin
                      ? await ChatLock.promptVerify(context)
                      : await ChatLock.promptSetup(context);
                  if (ok) {
                    await widget.store.preferences.setBool(
                      _lockKey,
                      !wasLocked,
                    );
                    if (mounted) setState(() {});
                  }
                case 'starred':
                  await _showStarred();
                case 'wallpaper':
                  await _chooseWallpaper();
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
                    messenger.showSnackBar(
                      SnackBar(content: Text('Error: $e')),
                    );
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
                case 'export':
                  await _exportChat();
                case 'storage':
                  await _showStorage();
                case 'tone':
                  await _pickTone();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'lock',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.lock_outline),
                  title: Text('Toggle chat PIN lock'),
                ),
              ),
              PopupMenuItem(
                value: 'starred',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.star_outline),
                  title: Text('Starred messages'),
                ),
              ),
              PopupMenuItem(
                value: 'wallpaper',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.wallpaper_outlined),
                  title: Text('Chat wallpaper & theme'),
                ),
              ),
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
              PopupMenuItem(
                value: 'export',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.ios_share_outlined),
                  title: Text('Export chat (.txt)'),
                ),
              ),
              PopupMenuItem(
                value: 'storage',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.storage_outlined),
                  title: Text('Storage info'),
                ),
              ),
              PopupMenuItem(
                value: 'tone',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.notifications_outlined),
                  title: Text('Notification tone'),
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (_searching)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Filter by date',
                    icon: const Icon(Icons.calendar_month_outlined),
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: context,
                        firstDate: DateTime(2020),
                        lastDate: DateTime.now(),
                        initialDate: _searchDate ?? DateTime.now(),
                      );
                      if (mounted) setState(() => _searchDate = picked);
                    },
                  ),
                  if (_searchDate != null)
                    InputChip(
                      label: Text(
                        '${_searchDate!.day}/${_searchDate!.month}/${_searchDate!.year}',
                      ),
                      onDeleted: () => setState(() => _searchDate = null),
                    ),
                  const SizedBox(width: 8),
                  DropdownButton<String?>(
                    value: _searchMedia,
                    hint: const Text('Media'),
                    items: const [
                      DropdownMenuItem(value: null, child: Text('All')),
                      DropdownMenuItem(value: 'img', child: Text('Photos')),
                      DropdownMenuItem(value: 'vid', child: Text('Videos')),
                      DropdownMenuItem(value: 'voice', child: Text('Audio')),
                      DropdownMenuItem(value: 'doc', child: Text('Docs')),
                      DropdownMenuItem(
                        value: 'contact',
                        child: Text('Contacts'),
                      ),
                      DropdownMenuItem(value: 'loc', child: Text('Location')),
                      DropdownMenuItem(value: 'poll', child: Text('Polls')),
                    ],
                    onChanged: (v) => setState(() => _searchMedia = v),
                  ),
                  const Spacer(),
                  if (_searchDate != null || _searchMedia != null)
                    TextButton(
                      onPressed: () => setState(() {
                        _searchDate = null;
                        _searchMedia = null;
                      }),
                      child: const Text('Clear'),
                    ),
                ],
              ),
            ),
          if (_documentControl != null)
            ListTile(
              title: LinearProgressIndicator(value: _documentProgress),
              subtitle: Text(
                'Uploading document ${(100 * _documentProgress).round()}%',
              ),
              trailing: IconButton(
                tooltip: 'Cancel upload',
                icon: const Icon(Icons.close),
                onPressed: () => _documentControl?.cancelled = true,
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (!_loading && !_peerConnected) _connectionBanner(),
          Expanded(
            child: WhatsAppWallpaper(
              preset: _wallpaperPreset,
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
                        final visible = msgs.where((m) {
                          final kind = parseMessageBody(m.text);
                          if (kind.isVote || kind.isDelete) return false;
                          if (_searchQuery.isNotEmpty &&
                              !_searchText(m).contains(_searchQuery)) {
                            return false;
                          }
                          if (_searchDate != null) {
                            final a = m.at.toLocal();
                            final b = _searchDate!.toLocal();
                            if (a.year != b.year ||
                                a.month != b.month ||
                                a.day != b.day) {
                              return false;
                            }
                          }
                          if (_searchMedia != null) {
                            final t = _searchMedia!;
                            final ok = switch (t) {
                              'img' => kind.isImage,
                              'vid' => kind.isVideo,
                              'voice' => kind.isVoice,
                              'doc' => kind.isDocument,
                              'contact' => kind.isContact,
                              'loc' => kind.isLocation,
                              'poll' => kind.isPoll,
                              _ => true,
                            };
                            if (!ok) return false;
                          }
                          return true;
                        }).toList();
                        if (visible.isEmpty) {
                          return Center(
                            child: Text(
                              _searchQuery.isNotEmpty
                                  ? 'No matches for "$_searchQuery".'
                                  : 'No messages yet. Say hello!',
                            ),
                          );
                        }
                        final records = msgs
                            .map((m) => (text: m.text, mine: m.mine))
                            .toList();
                        // Newest at the bottom: the reversed list lays index
                        // 0 at the bottom edge, so feed newest-first.
                        final ordered = visible.reversed.toList();
                        final reactions = widget.store.secureReactions(
                          accountId,
                          widget.peerId,
                        );
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
                            if (body.viewOnce) {
                              bubble = Align(
                                alignment: msg.mine
                                    ? Alignment.centerRight
                                    : Alignment.centerLeft,
                                child: Card(
                                  child: ListTile(
                                    leading: const Icon(
                                      Icons.filter_1_outlined,
                                    ),
                                    title: Text(
                                      msg.mine
                                          ? 'View-once media sent'
                                          : 'View-once ${body.isVideo ? 'video' : 'photo'}',
                                    ),
                                    subtitle: Text(
                                      msg.mine
                                          ? 'Recipients can open it once.'
                                          : 'Tap to open once. Capture protection required.',
                                    ),
                                    onTap: msg.mine
                                        ? null
                                        : () => Navigator.of(context).push(
                                            MaterialPageRoute<void>(
                                              builder: (_) => ViewOnceScreen(
                                                body: body,
                                                media: media,
                                                store: widget.store,
                                                account: accountId,
                                                peer: widget.peerId,
                                                messageRef: msg.ref,
                                              ),
                                            ),
                                          ),
                                  ),
                                ),
                              );
                            } else if (body.isTombstone) {
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
                                edited: msg.edited,
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
                                onVote: (choices) async {
                                  final sent = await _transmit(
                                    encodeVoteBody(body.pollId!, choices),
                                  );
                                  if (!sent && context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          'Vote failed to send. Check your connection.',
                                        ),
                                      ),
                                    );
                                  }
                                },
                              );
                            } else if (body.isDocument) {
                              bubble = DocumentBubble(
                                body: body,
                                transfer: documents,
                                mine: msg.mine,
                              );
                            } else if (body.isContact) {
                              bubble = ContactBubble(
                                body: body,
                                mine: msg.mine,
                              );
                            } else if (body.isLocation &&
                                body.latitude != null &&
                                body.longitude != null) {
                              bubble = LocationBubble(
                                body: body,
                                mine: msg.mine,
                              );
                            } else if (body.isVoice && body.path != null) {
                              bubble = VoiceNoteBubble(
                                media: media,
                                body: body,
                                mine: msg.mine,
                                time: msg.at.toLocal(),
                                status: msg.status,
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
                                edited: msg.edited,
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
                            // Only plain text/reply bubbles react on single tap:
                            // media opens on tap, polls vote on tap.
                            final tappable =
                                !body.isTombstone &&
                                !body.isImage &&
                                !body.isVideo &&
                                !body.isVoice &&
                                !body.isDocument &&
                                !body.isContact &&
                                !body.isLocation &&
                                !body.isPoll &&
                                !body.isVote;
                            final showDay =
                                i == ordered.length - 1 ||
                                !sameDay(msg.at, ordered[i + 1].at);
                            final tile = GestureDetector(
                              key: ValueKey(msg.ref),
                              onTapDown: tappable
                                  ? (details) =>
                                        _tapPos = details.globalPosition
                                  : null,
                              onTap: tappable ? () => _showReactBar(msg) : null,
                              onHorizontalDragEnd: body.isTombstone
                                  ? null
                                  : (details) {
                                      if ((details.primaryVelocity ?? 0) >
                                          100) {
                                        _beginReply(msg);
                                      }
                                    },
                              // WhatsApp-style double-tap to heart.
                              onDoubleTap: body.isTombstone
                                  ? null
                                  : () {
                                      final side =
                                          (reactions[msg.ref] ?? {})['❤️'];
                                      _toggleReaction(
                                        msg,
                                        '❤️',
                                        side == 'mine' || side == 'both',
                                      );
                                    },
                              onLongPress: body.isTombstone
                                  ? null
                                  : () {
                                      HapticFeedback.mediumImpact();
                                      _messageActions(msg);
                                    },
                              child: Column(
                                crossAxisAlignment: msg.mine
                                    ? CrossAxisAlignment.end
                                    : CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  AppearOnce(
                                    key: ValueKey('msg-${msg.ref}'),
                                    child: bubble,
                                  ),
                                  if ((reactions[msg.ref] ?? {}).isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        top: 2,
                                        bottom: 10,
                                      ),
                                      child: Wrap(
                                        spacing: 4,
                                        children: [
                                          for (final entry
                                              in (reactions[msg.ref] ?? {})
                                                  .entries)
                                            GestureDetector(
                                              onTap: () => _toggleReaction(
                                                msg,
                                                entry.key,
                                                entry.value == 'mine' ||
                                                    entry.value == 'both',
                                              ),
                                              child: Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 8,
                                                      vertical: 2,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .surfaceContainerHighest,
                                                  borderRadius:
                                                      BorderRadius.circular(12),
                                                  border:
                                                      (entry.value == 'mine' ||
                                                          entry.value == 'both')
                                                      ? Border.all(
                                                          color: Theme.of(
                                                            context,
                                                          ).colorScheme.primary,
                                                        )
                                                      : null,
                                                ),
                                                child: Text(
                                                  entry.key,
                                                  style: const TextStyle(
                                                    fontSize: 13,
                                                  ),
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                            );
                            if (!showDay) return tile;
                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Center(child: DayPill(at: msg.at)),
                                tile,
                              ],
                            );
                          },
                        );
                      },
                    ),
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
                                  color: Theme.of(context).colorScheme.primary,
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
                          onPressed: () => setState(() => _replyTo = null),
                        ),
                      ],
                    ),
                  ),
                if (_editing != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      border: Border(
                        left: BorderSide(
                          color: Theme.of(context).colorScheme.tertiary,
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
                                'Editing message',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                  color: Theme.of(context).colorScheme.tertiary,
                                ),
                              ),
                              Text(
                                _editing!.text,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Cancel edit',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => setState(() {
                            _editing = null;
                            composer.clear();
                          }),
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
                      icon: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        child: _sendingText
                            ? const SizedBox(
                                key: ValueKey('sending'),
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.send, key: ValueKey('send')),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: AnimatedOpacity(
        opacity: _showJump ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        child: IgnorePointer(
          ignoring: !_showJump,
          child: FloatingActionButton.small(
            tooltip: 'Jump to latest',
            onPressed: () {
              if (scroll.hasClients) scroll.jumpTo(0);
            },
            child: const Icon(Icons.arrow_downward),
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.accent = false,
  });
  final IconData icon;
  final String label;
  final String value;
  final bool accent;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(
      icon,
      color: accent ? Theme.of(context).colorScheme.primary : null,
    ),
    title: Text(label),
    subtitle: Text(value),
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
    if (status == 'read') return const Color(0xFF53BDEB);
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
        color: widget.mine ? const Color(0xFF245CDB) : const Color(0xFFE9EDF4),
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
                  color: widget.mine ? Colors.white : const Color(0xFF22334E),
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
        return await ChatMedia(widget.client).downloadSealed(
          widget.thumbPath!,
          widget.thumbKey!,
          widget.thumbNonce!,
        );
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
      final bytes = await ChatMedia(widget.client)
          .downloadSealed(widget.path, widget.imageKey!, widget.imageNonce!);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) =>
              SealedVideoScreen(bytes: bytes, caption: widget.caption),
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
        color: widget.mine ? const Color(0xFF245CDB) : const Color(0xFFE9EDF4),
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
                        child: Icon(Icons.play_arrow, color: Colors.white),
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
                  color: widget.mine ? Colors.white : const Color(0xFF22334E),
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
              final fg = widget.mine ? Colors.white : const Color(0xFF22334E);
              return InkWell(
                onTap: () {
                  if (widget.multi) {
                    setState(() {
                      isMine ? selected.remove(i) : selected.add(i);
                    });
                  } else {
                    // Single choice: tapping an option votes immediately
                    // (WhatsApp-style). The Vote button remains as backup.
                    setState(() => selected = {i});
                    widget.onVote([i]);
                  }
                },
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
    this.edited = false,
  });
  final String text;
  final bool mine;
  final DateTime time;
  final String status;
  final String? quoteName;
  final String? quoteText;
  final bool deleted;
  final bool edited;

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
        boxShadow: mine
            ? [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 2,
                  offset: const Offset(0, 1),
                ),
              ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (quoteText != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: mine ? Colors.white12 : Colors.black12,
                border: Border(
                  left: BorderSide(
                    color: mine ? Colors.white70 : const Color(0xFF245CDB),
                    width: 3,
                  ),
                ),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    quoteName ?? '',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: mine ? Colors.white : const Color(0xFF22334E),
                    ),
                  ),
                  Text.rich(
                    TextSpan(
                      children: formatMessageSpans(
                        quoteText!,
                        TextStyle(
                          color: mine
                              ? Colors.white70
                              : const Color(0xFF22334E),
                        ),
                      ),
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          // Plain Text, not SelectableText: in-place selection registers
          // competing long-press recognizers that swallow the message
          // action sheet (on device and in tests). Copy lives in the
          // long-press menu, WhatsApp-style.
          if (deleted)
            Text(
              text,
              style: TextStyle(
                color: mine ? Colors.white : const Color(0xFF22334E),
                fontStyle: FontStyle.italic,
                fontSize: 15,
                height: 1.45,
              ),
            )
          else
            Text.rich(
              TextSpan(
                children: formatMessageSpans(
                  text,
                  TextStyle(
                    color: mine ? Colors.white : const Color(0xFF22334E),
                    fontSize: 15,
                    height: 1.45,
                  ),
                ),
              ),
            ),
          const SizedBox(height: 6),
          Text.rich(
            TextSpan(
              children: [
                if (edited && !deleted)
                  TextSpan(
                    text: '(Edited) ',
                    style: TextStyle(
                      fontSize: 10,
                      fontStyle: FontStyle.italic,
                      color: mine ? Colors.white70 : const Color(0xFF66748A),
                    ),
                  ),
                TextSpan(
                  text:
                      '${time.hour.toString().padLeft(2, "0")}:${time.minute.toString().padLeft(2, "0")}',
                  style: TextStyle(
                    fontSize: 10,
                    color: mine ? Colors.white70 : const Color(0xFF66748A),
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
