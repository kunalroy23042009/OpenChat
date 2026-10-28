import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'media/media_message.dart';
import 'security/secure_history_database.dart';

class ChatMessage {
  ChatMessage({required this.text, required this.mine, required this.at});
  final String text;
  final bool mine;
  final DateTime at;
  Map<String, dynamic> toJson() => {
    'text': text,
    'mine': mine,
    'at': at.toIso8601String(),
  };
  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    text: json['text'] as String,
    mine: json['mine'] as bool,
    at: DateTime.parse(json['at'] as String),
  );
}

class SecureMessage {
  SecureMessage({
    required this.text,
    required this.mine,
    required this.at,
    this.clientId = '',
    this.status = 'sent',
    this.envelopeId,
    this.peerClientId,
    this.deliveredAt,
    this.readAt,
    this.hidden = false,
    this.edited = false,
  });

  /// Decrypted body: raw text or an encoded image body.
  final String text;
  final bool mine;
  final DateTime at;

  /// Sender-side idempotency key; used to poll delivery ticks.
  final String clientId;

  /// Sender-side tick: 'sent', 'delivered', or 'read'. Incoming messages
  /// always carry the default.
  final String status;

  /// Server envelope id; used to dedupe inbox redelivery. Null for legacy
  /// rows and local echoes created before ticks existed.
  final String? envelopeId;

  /// Sender's client id on incoming rows (from the envelope metadata), so
  /// delete-for-everyone markers can match either side's identifier.
  final String? peerClientId;

  /// Server receipt timestamps (ISO-8601) once the tick poll reports them.
  final String? deliveredAt;
  final String? readAt;

  /// Retain only metadata for local deletion so redelivery cannot resurrect it.
  final bool hidden;

  /// In-place correction marker for "(Edited)" tag.
  final bool edited;
  static const deleteWindow = Duration(hours: 60);

  bool canDeleteForEveryone(DateTime now) =>
      mine &&
      clientId.isNotEmpty &&
      !hidden &&
      !parseMessageBody(text).isTombstone &&
      now.difference(at) >= Duration.zero &&
      now.difference(at) <= deleteWindow;

  SecureMessage withBody(String body, {bool? hidden, bool? edited}) =>
      SecureMessage(
        text: body,
        mine: mine,
        at: at,
        clientId: clientId,
        status: status,
        envelopeId: envelopeId,
        peerClientId: peerClientId,
        deliveredAt: deliveredAt,
        readAt: readAt,
        hidden: hidden ?? this.hidden,
        edited: edited ?? this.edited,
      );
  Map<String, dynamic> toJson() => {
    'text': text,
    'mine': mine,
    'at': at.toIso8601String(),
    'clientId': clientId,
    'status': status,
    'envelopeId': envelopeId,
    'peerClientId': peerClientId,
    'deliveredAt': deliveredAt,
    'readAt': readAt,
    'hidden': hidden,
    'edited': edited,
  };
  factory SecureMessage.fromJson(Map<String, dynamic> json) => SecureMessage(
    text: json['text'] as String,
    mine: json['mine'] as bool,
    at: DateTime.parse(json['at'] as String),
    clientId: json['clientId'] as String? ?? '',
    status: json['status'] as String? ?? 'sent',
    envelopeId: json['envelopeId'] as String?,
    peerClientId: json['peerClientId'] as String?,
    deliveredAt: json['deliveredAt'] as String?,
    readAt: json['readAt'] as String?,
    hidden: json['hidden'] as bool? ?? false,
    edited: json['edited'] as bool? ?? false,
  );

  /// Stable identity for star/pin/delete: the sender-side key when known,
  /// else the envelope id, else a content fingerprint for legacy rows.
  String get ref {
    final id = mine ? clientId : (peerClientId ?? envelopeId ?? '');
    if (id.isNotEmpty) return '${mine ? 'out' : 'in'}:$id';
    return '${mine ? 'out' : 'in'}:${at.toIso8601String()}:$text';
  }

  /// Correctable within 15 minutes of sending: own text/reply rows with a
  /// sender key, never tombstones or hidden rows.
  static const editWindow = Duration(minutes: 15);

  bool canEdit(DateTime now) {
    if (!mine || clientId.isEmpty || hidden) return false;
    if (!parseMessageBody(text).isEditable) return false;
    final age = now.difference(at);
    return age >= Duration.zero && age <= editWindow;
  }
}

class Conversation {
  Conversation({
    required this.id,
    required this.name,
    required this.color,
    required this.messages,
    this.unread = 0,
    this.muted = false,
    this.mutedUntilMs,
    this.isAi = false,
    this.aiProvider,
    this.aiModel,
    this.archived = false,
    this.pinned = false,
    this.favourite = false,
    this.locked = false,
    this.markedUnread = false,
  });
  final String id;
  final String name;
  final int color;
  final List<ChatMessage> messages;
  int unread;

  /// WhatsApp-style visual reminder: a dot without a count on a chat the
  /// user deliberately flagged as needing another look. Cleared by
  /// [ChatStore.markRead].
  bool markedUnread;
  bool muted;

  /// Epoch millis when a timed mute ends. Null = muted indefinitely
  /// (Always) or not muted. Expired mutes read as unmuted via [isMutedNow].
  int? mutedUntilMs;
  final bool isAi;
  final String? aiProvider;
  final String? aiModel;

  /// Organization flags. All default false so every historical row parses.
  bool archived;
  bool pinned;
  bool favourite;
  bool locked;
  bool isTyping = false;

  /// True while a mute is active. Timed mutes expire by the clock without
  /// needing a write; the stale flag is cleared lazily on next mute change.
  bool get isMutedNow =>
      muted &&
      (mutedUntilMs == null ||
          DateTime.now().millisecondsSinceEpoch < mutedUntilMs!);

  String get initials => name
      .trim()
      .split(RegExp(r'\s+'))
      .take(2)
      .map((s) => s[0])
      .join()
      .toUpperCase();
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'color': color,
    'unread': unread,
    'muted': muted,
    'mutedUntil': mutedUntilMs,
    'isAi': isAi,
    'aiProvider': aiProvider,
    'aiModel': aiModel,
    'archived': archived,
    'pinned': pinned,
    'favourite': favourite,
    'locked': locked,
    'markedUnread': markedUnread,
    'messages': messages.map((m) => m.toJson()).toList(),
  };
  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
    id: json['id'] as String,
    name: json['name'] as String,
    color: json['color'] as int,
    unread: json['unread'] as int,
    muted: json['muted'] as bool? ?? false,
    mutedUntilMs: (json['mutedUntil'] as num?)?.toInt(),
    isAi: json['isAi'] as bool? ?? false,
    aiProvider: json['aiProvider'] as String?,
    aiModel: json['aiModel'] as String?,
    archived: json['archived'] as bool? ?? false,
    pinned: json['pinned'] as bool? ?? false,
    favourite: json['favourite'] as bool? ?? false,
    locked: json['locked'] as bool? ?? false,
    markedUnread: json['markedUnread'] as bool? ?? false,
    messages: (json['messages'] as List)
        .map((m) => ChatMessage.fromJson(Map<String, dynamic>.from(m as Map)))
        .toList(),
  );
}

/// Demo data only. Never use this plaintext storage for production messages.
class ChatStore extends ChangeNotifier {
  /// Fictional sample conversations shipped with fresh installs. The
  /// production app purges these on startup so the home screen opens clean;
  /// tests keep them via [purgeDemoSeeds] = false.
  static const demoSeedIds = {'maya', 'leo', 'aisha', 'noah'};

  ChatStore(
    this.preferences, {
    bool purgeDemoSeeds = false,
    this.secureHistory,
  }) {
    final saved = preferences.getString(storageKey);
    try {
      conversations = saved == null
          ? _seed()
          : (jsonDecode(saved) as List)
                .map(
                  (c) => Conversation.fromJson(
                    Map<String, dynamic>.from(c as Map),
                  ),
                )
                .toList();
    } catch (_) {
      conversations = _seed();
      storageWarning = 'Saved demo data could not be read. Sample conversations were restored.';
    }
    // Purge demo conversations: the fictional seeds and anything created
    // by the legacy name-only dialog (numeric microsecond ids). Real
    // conversations use '_secure_...', '_self_notes' or server UUID ids.
    if (purgeDemoSeeds) {
      bool isDemo(Conversation c) =>
          demoSeedIds.contains(c.id) || RegExp(r'^[0-9]+$').hasMatch(c.id);
      if (conversations.any(isDemo)) {
        conversations.removeWhere(isDemo);
        _save();
      }
    }
    // AI chatbot removed: drop any legacy AI threads without deleting
    // real chats. Keeps home list clean after upgrade.
    if (conversations.any((c) => c.isAi)) {
      conversations.removeWhere((c) => c.isAi);
      _save();
    }
    // Restore secure (1:1) conversations from encrypted local history.
    if (secureHistory != null) {
      _restoreSecureConversations();
    }
  }

  void _restoreSecureConversations() {
    if (secureHistory == null) return;
    final prefix = _securePrefix;
    try {
      final entries = secureHistory!.readEntries(prefix);
      for (final key in entries.keys) {
        final parsed = _parseSecureKey(key);
        if (parsed == null) continue;
        // Load this secure conversation (creates Conversation if missing).
        // The chain outlives the constructor; failures must stay silent so
        // the conversation list remains usable and tests can close the
        // database while a restore is still pending.
        unawaited(
          _ensureSecureConversation(parsed.accountId, parsed.peerId)
              .then(
                (_) => loadSecureConversation(parsed.accountId, parsed.peerId),
              )
              .catchError((_) {}),
        );
      }
    } catch (_) {
      // Ignore restore failures; conversation list remains usable.
    }
  }

  /// Key layout: `openchat.secure.v1.{accountId}-{peerId}`. Server account
  /// ids are UUIDs (36 chars), so a leading UUID-shaped segment is preferred;
  /// tests and legacy data use plain names, which split on the first dash.
  static ({String accountId, String peerId})? _parseSecureKey(String key) {
    if (!key.startsWith(_securePrefix)) return null;
    return parseSecureConversationId(key.substring(_securePrefix.length));
  }

  /// Splits a secure conversation id (`_secure_{accountId}-{peerId}`) into
  /// its account and peer parts so callers can resolve display names.
  /// UUID-shaped segments are preferred; legacy data splits on the first
  /// dash.
  static ({String accountId, String peerId})? parseSecureConversationId(
    String id,
  ) {
    if (!id.startsWith(_secureIdPrefix)) return null;
    final rest = id.substring(_secureIdPrefix.length);
    if (rest.length >= 38 && rest.codeUnitAt(36) == 0x2D /* - */) {
      final head = rest.substring(0, 36);
      if (_isUuidShape(head)) {
        final peerId = rest.substring(37);
        if (peerId.isNotEmpty) return (accountId: head, peerId: peerId);
      }
    }
    final split = rest.indexOf('-');
    if (split <= 0 || split == rest.length - 1) return null;
    return (
      accountId: rest.substring(0, split),
      peerId: rest.substring(split + 1),
    );
  }

  static bool _isUuidShape(String value) {
    const hyphenPositions = {8, 13, 18, 23};
    for (var i = 0; i < value.length; i++) {
      if (hyphenPositions.contains(i)) {
        if (value.codeUnitAt(i) != 0x2D) return false;
        continue;
      }
      final code = value.codeUnitAt(i);
      final isHex =
          (code >= 0x30 && code <= 0x39) ||
          (code >= 0x41 && code <= 0x46) ||
          (code >= 0x61 && code <= 0x66);
      if (!isHex) return false;
    }
    return true;
  }
  static const storageKey = 'openchat.demo.v1';
  final SharedPreferences preferences;
  final SecureHistoryDatabase? secureHistory;
  late List<Conversation> conversations;
  String? storageWarning;

  Future<void> _save() async {
    notifyListeners();
    try {
      final ok = await preferences.setString(
        storageKey,
        jsonEncode(conversations.map((c) => c.toJson()).toList()),
      );
      if (!ok) throw StateError('Save failed');
    } catch (_) {
      storageWarning = 'Demo changes could not be saved on this device.';
      notifyListeners();
    }
  }

  /// Reads the encrypted payload for [key]. A closed/uninitialized database
  /// (app teardown races) must not throw here: callers treat null as
  /// "nothing stored" and the read-only preferences fallback is safe.
  String? _securePayload(String key) {
    final db = secureHistory;
    if (db != null && db.isInitialized) return db.read(key);
    return preferences.getString(key);
  }

  /// Removes a local/demo conversation (swipe-to-delete). Encrypted
  /// cloud chats are managed through contacts, not here.
  Future<void> deleteConversation(String id) async {
    conversations.removeWhere((c) => c.id == id);
    await _save();
  }

  Future<void> _setFlag(String id, void Function(Conversation c) apply) async {
    for (final c in conversations) {
      if (c.id == id) apply(c);
    }
    await _save();
  }

  /// Archive is the safe remove: chats leave the list but stay recoverable
  /// under the Archived filter instead of being destroyed.
  Future<void> setArchived(String id, bool value) =>
      _setFlag(id, (c) => c.archived = value);

  Future<void> setPinned(String id, bool value) =>
      _setFlag(id, (c) => c.pinned = value);

  Future<void> setFavourite(String id, bool value) =>
      _setFlag(id, (c) => c.favourite = value);

  Future<void> setLocked(String id, bool value) =>
      _setFlag(id, (c) => c.locked = value);

  /// Applies a resolved display name (contacts list or profiles table) to
  /// a conversation row, e.g. one still showing the 'Loading...' placeholder.
  /// No-op when the row is missing or the name is unchanged.
  Future<void> renameConversation(String id, String name) async {
    final clean = name.trim();
    final idx = conversations.indexWhere((c) => c.id == id);
    if (idx < 0 || clean.isEmpty || conversations[idx].name == clean) return;
    final current = conversations[idx];
    conversations[idx] = Conversation(
      id: current.id,
      name: clean,
      color: current.color,
      messages: current.messages,
      unread: current.unread,
      muted: current.muted,
      mutedUntilMs: current.mutedUntilMs,
      archived: current.archived,
      pinned: current.pinned,
      favourite: current.favourite,
      locked: current.locked,
      markedUnread: current.markedUnread,
    );
    await _save();
  }

  Future<void> send(Conversation chat, String text) async {
    final clean = text.trim();
    if (clean.isEmpty || clean.length > 4000) return;
    chat.messages.add(ChatMessage(text: clean, mine: true, at: DateTime.now()));
    conversations.remove(chat);
    conversations.insert(0, chat);
    await _save();
  }

  Future<void> markRead(Conversation chat) async {
    chat.unread = 0;
    chat.markedUnread = false;
    await _save();
  }

  /// WhatsApp-style flag: keeps a dot (no count) on the chat list until
  /// the chat is opened or the flag is cleared.
  Future<void> setMarkedUnread(String id, bool value) =>
      _setFlag(id, (c) => c.markedUnread = value);

  Future<void> toggleMute(Conversation chat) async {
    if (chat.isMutedNow) {
      chat.muted = false;
      chat.mutedUntilMs = null;
    } else {
      chat.muted = true;
      chat.mutedUntilMs = null;
    }
    await _save();
  }

  /// WhatsApp-style mute durations. Null duration = Always.
  Future<void> setMute(Conversation chat, Duration? duration) async {
    chat.muted = true;
    chat.mutedUntilMs = duration == null
        ? null
        : DateTime.now().add(duration).millisecondsSinceEpoch;
    await _save();
  }

  Future<Conversation> create(String name) async {
    final clean = name.trim();
    if (clean.isEmpty || clean.length > 60) {
      throw ArgumentError('Name must contain 1–60 characters.');
    }
    final chat = Conversation(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: clean,
      color: 0xFFDBE6FF,
      messages: [],
    );
    conversations.insert(0, chat);
    await _save();
    return chat;
  }

  Future<void> reset() async {
    conversations = _seed();
    storageWarning = null;
    await _save();
  }

  // ==== Secure (encrypted) conversation storage ====
  // Separate namespace to avoid mixing with demo data.

  static const _securePrefix = 'openchat.secure.v1.';

  // SharedPreferences is a read/modify/write store. Realtime delivery,
  // inbox polling, and the composer can all update the same conversation at
  // once, so writes must be serialized per conversation or the last writer
  // can accidentally erase messages written by the other operation.
  final Map<String, Future<void>> _secureWriteQueues = {};

  Future<void> _queueSecureWrite(String key, Future<void> Function() write) {
    final previous = _secureWriteQueues[key] ?? Future<void>.value();
    late final Future<void> current;
    current = previous.catchError((_) {}).then((_) => write()).whenComplete(() {
      if (identical(_secureWriteQueues[key], current)) {
        _secureWriteQueues.remove(key);
      }
    });
    _secureWriteQueues[key] = current;
    return current;
  }

  Future<void> loadSecureConversation(String accountId, String peerId) async {
    final key = _secureKey(accountId, peerId);
    await purgeExpiredSecureMessages(accountId, peerId);
    final saved = _securePayload(key);
    if (saved == null) return;
    try {
      final data = jsonDecode(saved) as Map<String, dynamic>;
      final list = (data['messages'] as List)
          .map(
            (m) => SecureMessage.fromJson(Map<String, dynamic>.from(m as Map)),
          )
          .toList();
      // Find or create the secure conversation
      final existing = conversations.indexWhere(
        (c) => c.id == _secureId(accountId, peerId),
      );
      if (existing >= 0) {
        final current = conversations[existing];
        conversations[existing] = Conversation(
          id: current.id,
          name: current.name,
          color: current.color,
          messages: list
              .map((m) => ChatMessage(text: m.text, mine: m.mine, at: m.at))
              .toList(),
          unread: current.unread,
          muted: current.muted,
          mutedUntilMs: current.mutedUntilMs,
          archived: current.archived,
          pinned: current.pinned,
          favourite: current.favourite,
          locked: current.locked,
          markedUnread: current.markedUnread,
        );
      } else {
        await _ensureSecureConversation(accountId, peerId);
        // Reload to populate messages
        final newIdx = conversations.indexWhere(
          (c) => c.id == _secureId(accountId, peerId),
        );
        if (newIdx >= 0) {
          conversations[newIdx] = Conversation(
            id: conversations[newIdx].id,
            name: conversations[newIdx].name,
            color: conversations[newIdx].color,
            messages: list
                .map((m) => ChatMessage(text: m.text, mine: m.mine, at: m.at))
                .toList(),
            unread: conversations[newIdx].unread,
            muted: conversations[newIdx].muted,
            mutedUntilMs: conversations[newIdx].mutedUntilMs,
            archived: conversations[newIdx].archived,
            pinned: conversations[newIdx].pinned,
            favourite: conversations[newIdx].favourite,
            locked: conversations[newIdx].locked,
            markedUnread: conversations[newIdx].markedUnread,
          );
        }
      }
    } catch (_) {
      // Corrupt or missing secure data; ignore.
    }
  }

  Future<void> _ensureSecureConversation(String accountId, String peerId) async {
    final secureId = _secureId(accountId, peerId);
    final existing = conversations.indexWhere((c) => c.id == secureId);
    if (existing >= 0) return;
    // Create a minimal conversation entry for this peer.
    // Name/color will be updated when the contact is resolved.
    conversations.insert(0, Conversation(
      id: secureId,
      name: 'Loading...',
      color: 0xFFDDE5FF,
      messages: [],
      unread: 0,
    ));
    await _save();
  }

  static const _secureIdPrefix = '_secure_';

  static String _secureId(String accountId, String peerId) =>
      '$_secureIdPrefix$accountId-$peerId';

  /// True when the 1:1 secure chat with [peerId] is muted right now.
  /// Used to suppress notifications for muted chats, WhatsApp-style.
  bool isPeerMuted(String accountId, String peerId) {
    final secureId = _secureId(accountId, peerId);
    for (final c in conversations) {
      if (c.id == secureId) return c.isMutedNow;
    }
    return false;
  }

  static String _secureKey(String accountId, String peerId) =>
      '$_securePrefix$accountId-$peerId';

  Future<void> addSecureMessage(
    String accountId,
    String peerId,
    String text, {
    required bool mine,
    String clientId = '',
    String? envelopeId,
    String? peerClientId,
    DateTime? at,
  }) async {
    final key = _secureKey(accountId, peerId);
    await _queueSecureWrite(key, () async {
      // A corrupt history must never be replaced by an empty conversation.
      final messages = _readSecureMessages(key);
      // Envelope ids are unique for incoming messages. Client ids are unique
      // for outgoing messages, including a retry that the server reports as
      // a duplicate. Checking both makes delivery idempotent locally.
      if ((envelopeId != null &&
              messages.any((m) => m.envelopeId == envelopeId)) ||
          (clientId.isNotEmpty &&
              messages.any((m) => m.mine && m.clientId == clientId)) ||
          (!mine &&
              peerClientId != null &&
              peerClientId.isNotEmpty &&
              messages.any((m) => !m.mine && m.peerClientId == peerClientId))) {
        return;
      }
      messages.add(
        SecureMessage(
          text: text,
          mine: mine,
          at: at ?? DateTime.now(),
          clientId: clientId,
          envelopeId: envelopeId,
          peerClientId: peerClientId,
        ),
      );
      // Keep delete/edit controls for idempotency and out-of-order
      // delivery. Only the author can retract or correct their own
      // message: deletes within one hour, edits within 15 minutes of the
      // send timestamp. Replacing in place preserves receipt metadata.
      for (final control in messages.where(
        (m) =>
            parseMessageBody(m.text).isDelete ||
            parseMessageBody(m.text).isEdit,
      )) {
        final body = parseMessageBody(control.text);
        final target = body.target;
        if (target == null || target.isEmpty) continue;
        final window = body.isDelete
            ? SecureMessage.deleteWindow
            : SecureMessage.editWindow;
        for (var i = 0; i < messages.length; i++) {
          final m = messages[i];
          final id = m.mine ? m.clientId : m.peerClientId;
          final age = control.at.difference(m.at);
          if (m.mine == control.mine &&
              id == target &&
              age >= Duration.zero &&
              age <= window) {
            final original = parseMessageBody(m.text);
            if (original.isControl) continue;
            if (body.isDelete) {
              messages[i] = m.withBody(encodeTombstoneBody());
            } else if (original.isEditable) {
              // Media/poll bodies reject correction; the control is kept
              // for idempotency but changes nothing.
              messages[i] = m.withBody(
                preserveMessageExpiry(m.text, original.editedBody(body.text)),
                edited: true,
              );
            }
          }
        }
      }
      // Stable chronological ordering, including equal timestamps.
      final ordered = messages.asMap().entries.toList()
        ..sort((a, b) {
          final time = a.value.at.compareTo(b.value.at);
          return time == 0 ? a.key.compareTo(b.key) : time;
        });
      await _writeSecureMessages(
        accountId,
        peerId,
        ordered.map((e) => e.value).toList(),
      );
    });
  }

  List<SecureMessage> _readSecureMessages(String key) {
    final saved = _securePayload(key);
    if (saved == null) return [];
    final rows = (jsonDecode(saved) as Map)['messages'] as List;
    return rows
        .map(
          (row) =>
              SecureMessage.fromJson(Map<String, dynamic>.from(row as Map)),
        )
        .toList();
  }

  Future<void> _writeSecureMessages(
    String accountId,
    String peerId,
    List<SecureMessage> messages,
  ) async {
    final key = _secureKey(accountId, peerId);
    final active = messages
        .where((message) => !messageHasExpired(message.text))
        .toList();
    final payload = jsonEncode({
      'messages': active.map((m) => m.toJson()).toList(),
    });
    if (secureHistory != null) {
      await secureHistory!.write(key, payload);
    } else {
      final ok = await preferences.setString(key, payload);
      if (!ok) throw StateError('Secure save failed');
    }
    _syncSecureConversation(
      accountId,
      peerId,
      active.where((m) {
        if (m.hidden) return false;
        final kind = parseMessageBody(m.text);
        // Ballots stay for tallies; tombstones render. Delete, reaction
        // and edit markers are applied-then-dropped transport only.
        return !kind.isDelete && !kind.isReact && !kind.isEdit;
      }).toList(),
    );
    notifyListeners();
  }

  void _syncSecureConversation(
    String accountId,
    String peerId,
    List<SecureMessage> messages,
  ) {
    final secureId = _secureId(accountId, peerId);
    final idx = conversations.indexWhere((c) => c.id == secureId);
    if (idx < 0) return;
    final current = conversations[idx];
    conversations[idx] = Conversation(
      id: current.id,
      name: current.name,
      color: current.color,
      messages: messages
          .map((m) => ChatMessage(text: m.text, mine: m.mine, at: m.at))
          .toList(),
      unread: current.unread,
      muted: current.muted,
      mutedUntilMs: current.mutedUntilMs,
      archived: current.archived,
      pinned: current.pinned,
      favourite: current.favourite,
      locked: current.locked,
    );
  }

  List<SecureMessage> getSecureConversation(String accountId, String peerId) {
    final key = _secureKey(accountId, peerId);
    final saved = _securePayload(key);
    if (saved == null) return [];
    try {
      return _readSecureMessages(key).where((m) {
        if (m.hidden || messageHasExpired(m.text)) return false;
        final kind = parseMessageBody(m.text);
        return !kind.isDelete && !kind.isReact && !kind.isEdit;
      }).toList();
    } catch (_) {
      storageWarning = 'Saved encrypted-chat history could not be read. The original data has been preserved.';
      return [];
    }
  }

  /// Permanently drops expired bodies from encrypted local history. Filtering
  /// in [getSecureConversation] prevents stale rows from flashing before this
  /// cooperative cleanup runs on chat open or at the expiry deadline.
  Future<int> purgeExpiredSecureMessages(
    String accountId,
    String peerId,
  ) async {
    final key = _secureKey(accountId, peerId);
    var removed = 0;
    await _queueSecureWrite(key, () async {
      if (_securePayload(key) == null) return;
      final messages = _readSecureMessages(key);
      final expired = messages
          .where((message) => messageHasExpired(message.text))
          .map((message) => message.ref)
          .toSet();
      if (expired.isEmpty) return;
      messages.removeWhere((message) => expired.contains(message.ref));
      await _writeSecureMessages(accountId, peerId, messages);
      final stars =
          preferences.getStringList(_starKey(accountId, peerId)) ?? [];
      await preferences.setStringList(
        _starKey(accountId, peerId),
        stars.where((ref) => !expired.contains(ref)).toList(),
      );
      final pins = preferences.getStringList(_pinKey(accountId, peerId)) ?? [];
      await preferences.setStringList(
        _pinKey(accountId, peerId),
        pins.where((ref) => !expired.contains(ref)).toList(),
      );
      removed = expired.length;
    });
    return removed;
  }

  bool hasSecureEnvelope(String accountId, String peerId, String envelopeId) {
    if (envelopeId.isEmpty) return false;
    return _readSecureMessages(_secureKey(accountId, peerId))
        .any((m) => m.envelopeId == envelopeId);
  }

  /// Updates the sender-side tick (plus server receipt timestamps) for a
  /// local echo. No-op when the row is missing (e.g. cleared history).
  Future<void> updateSecureStatus(
    String accountId,
    String peerId,
    String clientId,
    String status, {
    String? deliveredAt,
    String? readAt,
  }) async {
    if (clientId.isEmpty) return;
    final key = _secureKey(accountId, peerId);
    await _queueSecureWrite(key, () async {
      final saved = _securePayload(key);
      if (saved == null) return;
      final messages = _readSecureMessages(key);
      var changed = false;
      for (var i = 0; i < messages.length; i++) {
        final m = messages[i];
        if (m.mine && m.clientId == clientId) {
          const ranks = {'sent': 0, 'delivered': 1, 'read': 2};
          if (!ranks.containsKey(status)) continue;
          final nextStatus = ranks[status]! >= (ranks[m.status] ?? 0)
              ? status
              : m.status;
          final nextDelivered = deliveredAt ?? m.deliveredAt;
          final nextRead = readAt ?? m.readAt;
          if (m.status != nextStatus ||
              m.deliveredAt != nextDelivered ||
              m.readAt != nextRead) {
            messages[i] = SecureMessage(
              text: m.text,
              mine: m.mine,
              at: m.at,
              clientId: m.clientId,
              status: nextStatus,
              hidden: m.hidden,
              envelopeId: m.envelopeId,
              peerClientId: m.peerClientId,
              deliveredAt: nextDelivered,
              readAt: nextRead,
              edited: m.edited,
            );
            changed = true;
          }
        }
      }
      if (!changed) return;
      await _writeSecureMessages(accountId, peerId, messages);
    });
  }

  /// Removes one stored message by sender key or envelope id. Returns true
  /// when something was removed.
  Future<bool> removeSecureMessage(
    String accountId,
    String peerId,
    String ref,
  ) async {
    if (ref.isEmpty) return false;
    final key = _secureKey(accountId, peerId);
    var removed = false;
    await _queueSecureWrite(key, () async {
      final saved = _securePayload(key);
      if (saved == null) return;
      final messages = _readSecureMessages(key);
      final i = messages.indexWhere((m) => m.ref == ref && !m.hidden);
      if (i < 0) return;
      messages[i] = messages[i].withBody(encodeTombstoneBody(), hidden: true);
      await _writeSecureMessages(accountId, peerId, messages);
      removed = true;
    });
    return removed;
  }

  /// Edits a 1:1 secure message by sending an edit control message.
  /// Only works within 15 minutes of sending (WhatsApp parity).
  Future<bool> editSecureMessage(
    String accountId,
    String peerId,
    String ref,
    String newText,
    MethodChannel channel,
  ) async {
    if (ref.isEmpty || newText.isEmpty) return false;
    final key = _secureKey(accountId, peerId);
    var success = false;
    await _queueSecureWrite(key, () async {
      final messages = _readSecureMessages(key);
      final i = messages.indexWhere((m) => m.ref == ref && !m.hidden && m.mine);
      if (i < 0) return;
      final message = messages[i];
      if (!message.canEdit(DateTime.now())) return;

      // Send edit control message via Signal
      try {
        final editBody = encodeEditBody(ref, newText);
        final result = await channel.invokeMethod('signalEncrypt', {
          'accountId': accountId,
          'peerId': peerId,
          'plain': base64Encode(utf8.encode(editBody)),
        }) as Map<dynamic, dynamic>;

        await channel.invokeMethod('sendSignalMessage', {
          'accountId': accountId,
          'peerId': peerId,
          'type': result['type'],
          'body': result['body'],
        });

        // Update local message to the edited text (peer gets the control).
        final original = parseMessageBody(message.text);
        messages[i] = SecureMessage(
          text: preserveMessageExpiry(
            message.text,
            original.editedBody(newText),
          ),
          mine: true,
          at: message.at,
          clientId: message.clientId,
          status: message.status,
          envelopeId: message.envelopeId,
          peerClientId: message.peerClientId,
          deliveredAt: message.deliveredAt,
          readAt: message.readAt,
          edited: true,
        );
        await _writeSecureMessages(accountId, peerId, messages);
        success = true;
      } catch (_) {
        // Ignore failures - will retry on next send
      }
    });
    return success;
  }

  /// Deletes a 1:1 secure message (for me or for everyone).
  /// For everyone: sends delete control message within the supported window.
  /// For me: marks locally as hidden.
  Future<bool> deleteSecureMessage(
    String accountId,
    String peerId,
    String ref, {
    bool forEveryone = false,
    MethodChannel? channel,
  }) async {
    if (ref.isEmpty) return false;
    final key = _secureKey(accountId, peerId);
    var success = false;
    await _queueSecureWrite(key, () async {
      final messages = _readSecureMessages(key);
      final i = messages.indexWhere((m) => m.ref == ref && !m.hidden);
      if (i < 0) return;
      final message = messages[i];

      if (forEveryone) {
        if (!message.mine ||
            !message.canDeleteForEveryone(DateTime.now()) ||
            channel == null) {
          return;
        }
        // Send delete-for-everyone control message
        try {
          final deleteBody = encodeDeleteBody(ref);
          final result = await channel.invokeMethod('signalEncrypt', {
            'accountId': accountId,
            'peerId': peerId,
            'plain': base64Encode(utf8.encode(deleteBody)),
          }) as Map<dynamic, dynamic>;

          await channel.invokeMethod('sendSignalMessage', {
            'accountId': accountId,
            'peerId': peerId,
            'type': result['type'],
            'body': result['body'],
          });

          // Keep the tombstone visible locally, matching what the recipient
          // receives instead of making the sender's message silently vanish.
          messages[i] = messages[i].withBody(encodeTombstoneBody());
          await _writeSecureMessages(accountId, peerId, messages);
          success = true;
        } catch (_) {
          // Ignore failures
        }
      } else {
        // Delete for me only
        messages[i] = messages[i].withBody(encodeTombstoneBody(), hidden: true);
        await _writeSecureMessages(accountId, peerId, messages);
        success = true;
      }
    });
    return success;
  }

  /// Restores a delete-for-me tombstone within the undo window.
  /// Returns the restored body, or null when nothing was restored.
  Future<String?> restoreSecureMessage(
    String accountId,
    String peerId,
    String ref,
    String originalText,
  ) async {
    if (ref.isEmpty) return null;
    final key = _secureKey(accountId, peerId);
    String? done;
    await _queueSecureWrite(key, () async {
      final messages = _readSecureMessages(key);
      final i = messages.indexWhere((m) => m.ref == ref);
      if (i < 0) return;
      messages[i] = messages[i].withBody(originalText, hidden: false);
      await _writeSecureMessages(accountId, peerId, messages);
      done = originalText;
    });
    return done;
  }

  /// Toggles a reaction on a 1:1 message by sending a reaction control message.
  Future<void> reactToSecureMessage(
    String accountId,
    String peerId,
    String ref,
    String emoji,
    MethodChannel channel,
  ) async {
    if (ref.isEmpty || emoji.isEmpty) return;
    final key = _secureKey(accountId, peerId);
    await _queueSecureWrite(key, () async {
      final messages = _readSecureMessages(key);
      final i = messages.indexWhere((m) => m.ref == ref && !m.hidden);
      if (i < 0) return;

      // Send reaction control message
      try {
        final reactBody = encodeReactBody(ref, emoji);
        final result = await channel.invokeMethod('signalEncrypt', {
          'accountId': accountId,
          'peerId': peerId,
          'plain': base64Encode(utf8.encode(reactBody)),
        }) as Map<dynamic, dynamic>;

        await channel.invokeMethod('sendSignalMessage', {
          'accountId': accountId,
          'peerId': peerId,
          'type': result['type'],
          'body': result['body'],
        });
      } catch (_) {
        // Ignore failures
      }
    });
    // Also apply locally for instant feedback
    await applySecureReaction(
      accountId,
      peerId,
      ref,
      emoji,
      mine: true,
      remove: false,
    );
  }

  /// Atomically consumes a received view-once body before it is shown.
  /// Retains envelope identity for dedupe but erases the persisted key.
  Future<bool> consumeViewOnce(
    String accountId,
    String peerId,
    String ref,
  ) async {
    var consumed = false;
    await _queueSecureWrite(_secureKey(accountId, peerId), () async {
      final messages = _readSecureMessages(_secureKey(accountId, peerId));
      final index = messages.indexWhere(
        (m) =>
            m.ref == ref &&
            !m.mine &&
            !m.hidden &&
            parseMessageBody(m.text).viewOnce,
      );
      if (index < 0) return;
      messages[index] = messages[index].withBody(
        encodeTextBody('View-once media opened'),
      );
      await _writeSecureMessages(accountId, peerId, messages);
      consumed = true;
    });
    return consumed;
  }

  static String _starKey(String accountId, String peerId) =>
      'openchat.stars.v1.$accountId-$peerId';
  static String _pinKey(String accountId, String peerId) =>
      'openchat.pins.v1.$accountId-$peerId';

  Future<Set<String>> secureStars(String accountId, String peerId) async {
    final list = preferences.getStringList(_starKey(accountId, peerId));
    final available = getSecureConversation(accountId, peerId)
        .where((m) => !parseMessageBody(m.text).isTombstone)
        .map((m) => m.ref)
        .toSet();
    return (list ?? <String>[]).toSet().intersection(available);
  }

  Future<void> toggleSecureStar(
    String accountId,
    String peerId,
    String ref,
  ) async {
    await _queueSecureWrite(_secureKey(accountId, peerId), () async {
      final stars = await secureStars(accountId, peerId);
      if (stars.contains(ref)) {
        stars.remove(ref);
      } else {
        stars.add(ref);
      }
      await preferences.setStringList(
        _starKey(accountId, peerId),
        stars.toList(),
      );
      notifyListeners();
    });
  }

  Future<List<String>> securePins(String accountId, String peerId) async {
    final available = getSecureConversation(accountId, peerId)
        .where((m) => !parseMessageBody(m.text).isTombstone)
        .map((m) => m.ref)
        .toSet();
    return (preferences.getStringList(_pinKey(accountId, peerId)) ?? [])
        .where(available.contains)
        .toList();
  }

  /// Pin at most three messages without silently evicting an existing pin.
  Future<bool> pinSecureMessage(
    String accountId,
    String peerId,
    String ref,
  ) async {
    var pinned = false;
    await _queueSecureWrite(_secureKey(accountId, peerId), () async {
      final pins = await securePins(accountId, peerId);
      if (pins.contains(ref)) {
        pinned = true;
        return;
      }
      if (pins.length >= 3) return;
      pins.add(ref);
      await preferences.setStringList(_pinKey(accountId, peerId), pins);
      pinned = true;
      notifyListeners();
    });
    return pinned;
  }

  Future<void> unpinSecureMessage(
    String accountId,
    String peerId,
    String ref,
  ) async {
    await _queueSecureWrite(_secureKey(accountId, peerId), () async {
      final pins = await securePins(accountId, peerId);
      pins.remove(ref);
      await preferences.setStringList(_pinKey(accountId, peerId), pins);
      notifyListeners();
    });
  }

  Future<SecureMessage?> secureMessageByRef(
    String accountId,
    String peerId,
    String ref,
  ) async {
    for (final m in getSecureConversation(accountId, peerId)) {
      if (m.ref == ref || m.clientId == ref || m.envelopeId == ref) return m;
    }
    return null;
  }

  static String _reactKey(String accountId, String peerId) =>
      'openchat.reacts.v1.$accountId-$peerId';

  /// Reactions per message ref: `{ref: {emoji: 'mine'|'peer'|'both'}}`.
  /// Corrupt maps reset to empty; a corrupt map must never crash the build.
  Map<String, Map<String, String>> secureReactions(
    String accountId,
    String peerId,
  ) {
    final saved = preferences.getString(_reactKey(accountId, peerId));
    final result = <String, Map<String, String>>{};
    try {
      final decoded = jsonDecode(saved ?? '{}') as Map<String, dynamic>;
      result.addAll({
        for (final entry in decoded.entries)
          entry.key: {
            for (final vote in (entry.value as Map).entries)
              vote.key.toString(): vote.value.toString(),
          },
      });
    } catch (_) {}
    // Durable Signal control rows are the source of truth. A target carries
    // the original author's account id, so it resolves on either device.
    final messages = _readSecureMessages(_secureKey(accountId, peerId));
    final targets = messages
        .where((m) => !m.hidden && !parseMessageBody(m.text).isControl)
        .toList();
    for (final row in messages) {
      final body = parseMessageBody(row.text);
      if (!body.isReact) continue;
      final matches = targets.where((m) {
        final id = m.mine ? m.clientId : m.peerClientId;
        if (id == null || id.isEmpty) return false;
        return body.target == '${m.mine ? accountId : peerId}:$id' ||
            body.target == id;
      }).toList();
      if (matches.length != 1) continue; // Reject ambiguous legacy ids.
      final ref = matches.single.ref;
      final votes = result.putIfAbsent(ref, () => {});
      final own = row.mine ? 'mine' : 'peer';
      final other = row.mine ? 'peer' : 'mine';
      if (body.removed) {
        if (votes[body.text] == own) votes.remove(body.text);
        if (votes[body.text] == 'both') votes[body.text] = other;
      } else {
        // WhatsApp-style: each participant has one reaction per message.
        for (final emoji in votes.keys.toList()) {
          if (votes[emoji] == own) votes.remove(emoji);
          if (votes[emoji] == 'both') votes[emoji] = other;
        }
        votes[body.text] = votes[body.text] == other ? 'both' : own;
      }
      if (votes.isEmpty) result.remove(ref);
    }
    return result;
  }

  /// Applies an explicit reaction state (not a toggle), so redelivered
  /// markers converge instead of flapping.
  Future<void> applySecureReaction(
    String accountId,
    String peerId,
    String ref,
    String emoji, {
    required bool mine,
    required bool remove,
  }) async {
    if (ref.isEmpty || emoji.isEmpty) return;
    await _queueSecureWrite(_secureKey(accountId, peerId), () async {
      final all = secureReactions(accountId, peerId);
      final votes = Map<String, String>.from(all[ref] ?? {});
      final side = votes[emoji];
      final own = mine
          ? (side == 'mine' || side == 'both')
          : (side == 'peer' || side == 'both');
      final other = mine
          ? (side == 'peer' || side == 'both')
          : (side == 'mine' || side == 'both');
      if (remove) {
        if (other) {
          votes[emoji] = mine ? 'peer' : 'mine';
        } else {
          votes.remove(emoji);
        }
      } else if (!own && !other) {
        votes[emoji] = mine ? 'mine' : 'peer';
      } else if (!own && other) {
        votes[emoji] = 'both';
      }
      if (votes.isEmpty) {
        all.remove(ref);
      } else {
        all[ref] = votes;
      }
      await preferences.setString(
        _reactKey(accountId, peerId),
        jsonEncode(all),
      );
      notifyListeners();
    });
  }

  static String _draftKey(String accountId, String peerId) =>
      'openchat.drafts.v1.$accountId-$peerId';

  /// Unsent composer text per encrypted chat. Synchronous so every build
  /// can show the Draft prefix without a FutureBuilder.
  String secureDraft(String accountId, String peerId) =>
      preferences.getString(_draftKey(accountId, peerId)) ?? '';

  Future<void> setSecureDraft(
    String accountId,
    String peerId,
    String value,
  ) async {
    final wasEmpty = secureDraft(accountId, peerId).isEmpty;
    if (value.isEmpty) {
      await preferences.remove(_draftKey(accountId, peerId));
    } else {
      await preferences.setString(_draftKey(accountId, peerId), value);
    }
    // Only empty<->non-empty transitions change any UI (the home preview).
    if (wasEmpty == value.isEmpty) return;
    notifyListeners();
  }

  /// Full-fidelity export of every secure conversation for encrypted
  /// cloud backup. Raw rows (including tombstones/ballots) plus stars,
  /// pins, drafts, and the persisted reaction map — restore recomputes
  /// derived state identically.
  Map<String, dynamic> exportSecureBackup(String accountId) {
    final prefix = '$_securePrefix$accountId-';
    final peers = <String>{};
    for (final key in preferences.getKeys()) {
      if (key.startsWith(prefix)) peers.add(key.substring(prefix.length));
    }
    for (final key in secureHistory?.readEntries(prefix).keys ?? <String>[]) {
      peers.add(key.substring(prefix.length));
    }
    final out = <String, dynamic>{};
    for (final peerId in peers) {
      out[peerId] = {
        'messages': _readSecureMessages(_secureKey(accountId, peerId))
            .where((message) => !messageHasExpired(message.text))
            .map((m) => m.toJson())
            .toList(),
        'stars': preferences.getStringList(_starKey(accountId, peerId)) ?? [],
        'pins': preferences.getStringList(_pinKey(accountId, peerId)) ?? [],
        'draft': secureDraft(accountId, peerId),
        'reacts': preferences.getString(_reactKey(accountId, peerId)) ?? '{}',
      };
    }
    return out;
  }

  /// Merges a backup export into local state. Messages union by stable ref
  /// (never duplicates, never drops local-only rows); stars/pins union
  /// (pins keep the 3-slot cap); drafts fill only empty composers;
  /// reactions fill only refs without local votes. Returns message count.
  Future<int> importSecureBackup(
    String accountId,
    Map<String, dynamic> peers,
  ) async {
    var count = 0;
    for (final entry in peers.entries) {
      final peerId = entry.key;
      final data = Map<String, dynamic>.from(entry.value as Map);
      await _queueSecureWrite(_secureKey(accountId, peerId), () async {
        final current = _readSecureMessages(_secureKey(accountId, peerId));
        final seen = {for (final m in current) m.ref};
        final merged = List<SecureMessage>.from(current);
        for (final raw in (data['messages'] as List? ?? [])) {
          try {
            final m = SecureMessage.fromJson(
              Map<String, dynamic>.from(raw as Map),
            );
            if (!messageHasExpired(m.text) && seen.add(m.ref)) merged.add(m);
          } catch (_) {}
        }
        merged.sort((a, b) {
          final time = a.at.compareTo(b.at);
          return time == 0 ? a.ref.compareTo(b.ref) : time;
        });
        await _writeSecureMessages(accountId, peerId, merged);
        count += (data['messages'] as List? ?? []).length;
        final stars = {
          ...?preferences.getStringList(_starKey(accountId, peerId)),
          for (final s in (data['stars'] as List? ?? [])) s.toString(),
        };
        await preferences.setStringList(
          _starKey(accountId, peerId),
          stars.toList(),
        );
        final pins = [
          ...?preferences.getStringList(_pinKey(accountId, peerId)),
        ];
        for (final p in (data['pins'] as List? ?? [])) {
          if (pins.length >= 3) break;
          if (!pins.contains(p.toString())) pins.add(p.toString());
        }
        await preferences.setStringList(_pinKey(accountId, peerId), pins);
        if (secureDraft(accountId, peerId).isEmpty) {
          final draft = (data['draft'] ?? '').toString();
          if (draft.isNotEmpty) {
            await preferences.setString(_draftKey(accountId, peerId), draft);
          }
        }
        try {
          final restored = jsonDecode(
            (data['reacts'] ?? '{}').toString(),
          ) as Map<String, dynamic>;
          final local = jsonDecode(
            preferences.getString(_reactKey(accountId, peerId)) ?? '{}',
          ) as Map<String, dynamic>;
          for (final e in restored.entries) {
            local.putIfAbsent(e.key, () => e.value);
          }
          await preferences.setString(
            _reactKey(accountId, peerId),
            jsonEncode(local),
          );
        } catch (_) {}
        notifyListeners();
      });
    }
    return count;
  }

  static String _groupArchiveKey(String accountId, String conversationId) =>
      'openchat.groupArchive.v1.$accountId.$conversationId';

  String? groupArchive(String accountId, String conversationId) =>
      _securePayload(_groupArchiveKey(accountId, conversationId));

  /// Stores group history as an encrypted, read-only recovery archive.
  /// The live server remains authoritative for group membership and writes;
  /// importing a backup never impersonates another group member.
  Future<int> importGroupBackup(
    String accountId,
    Map<String, dynamic> groups,
  ) async {
    var count = 0;
    for (final entry in groups.entries) {
      final archive = Map<String, dynamic>.from(entry.value as Map);
      final messages = (archive['messages'] as List? ?? []);
      final key = _groupArchiveKey(accountId, entry.key);
      final local = _securePayload(key);
      final existing = local == null
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(local) as Map);
      final byId = <String, Map<String, dynamic>>{
        for (final raw in (existing['messages'] as List? ?? []))
          (raw as Map)['id'] as String: Map<String, dynamic>.from(raw),
        for (final raw in messages)
          (raw as Map)['id'] as String: Map<String, dynamic>.from(raw),
      };
      final merged = {
        'conversation': archive['conversation'],
        'messages': byId.values.toList()
          ..sort(
            (a, b) => (a['created_at'] as String).compareTo(
              b['created_at'] as String,
            ),
          ),
      };
      final encoded = jsonEncode(merged);
      if (secureHistory != null) {
        await secureHistory!.write(key, encoded);
      } else {
        await preferences.setString(key, encoded);
      }
      count += messages.length;
    }
    notifyListeners();
    return count;
  }

  static String _unreadKey(String accountId) => 'openchat.unread.v1.$accountId';

  /// Manual mark-unread flags per peer. Incoming messages in the open chat
  /// are read; anything else is the user's explicit reminder.
  bool secureUnread(String accountId, String peerId) =>
      preferences.getStringList(_unreadKey(accountId))?.contains(peerId) ??
      false;

  Future<void> setSecureUnread(
    String accountId,
    String peerId,
    bool value,
  ) async {
    final list = preferences.getStringList(_unreadKey(accountId)) ?? [];
    final has = list.contains(peerId);
    if (has == value) return;
    if (value) {
      list.add(peerId);
    } else {
      list.remove(peerId);
    }
    await preferences.setStringList(_unreadKey(accountId), list);
    notifyListeners();
  }

  /// Personal notes thread. Local-only: the server forbids sender ==
  /// recipient, so this never touches the encrypted transport.
  static const selfChatId = '_self_notes';

  Future<Conversation> ensureSelfChat() async {
    for (final c in conversations) {
      if (c.id == selfChatId) return c;
    }
    final chat = Conversation(
      id: selfChatId,
      name: 'Message yourself',
      color: 0xFFD2EEE5,
      messages: [
        ChatMessage(
          text: 'Your personal notes. Only you can see this conversation.',
          mine: false,
          at: DateTime.now(),
        ),
      ],
    );
    conversations.insert(0, chat);
    await _save();
    return chat;
  }

  static const _failPrefix = 'openchat.envelopeFails.v1.';

  int envelopeFailCount(String envelopeId) =>
      preferences.getInt('$_failPrefix$envelopeId') ?? 0;

  Future<void> recordEnvelopeFailure(String envelopeId) => preferences.setInt(
    '$_failPrefix$envelopeId',
    envelopeFailCount(envelopeId) + 1,
  );

  static List<Conversation> _seed() {
    final now = DateTime.now();
    return [
      Conversation(
        id: 'maya',
        name: 'Maya Chen',
        color: 0xFFDDE5FF,
        unread: 2,
        messages: [
          ChatMessage(
            text: 'Hey! Found a lovely spot for our weekend catch-up ☕',
            mine: false,
            at: now.subtract(const Duration(minutes: 24)),
          ),
          ChatMessage(
            text: 'The little place by the bookshop?',
            mine: true,
            at: now.subtract(const Duration(minutes: 22)),
          ),
          ChatMessage(
            text: 'That’s the one. Saturday at 10?',
            mine: false,
            at: now.subtract(const Duration(minutes: 20)),
          ),
        ],
      ),
      Conversation(
        id: 'leo',
        name: 'Leo Martins',
        color: 0xFFFFE4CA,
        unread: 1,
        messages: [
          ChatMessage(
            text: 'Made it home. Thanks for a great evening!',
            mine: false,
            at: now.subtract(const Duration(hours: 1)),
          ),
        ],
      ),
      Conversation(
        id: 'aisha',
        name: 'Aisha Patel',
        color: 0xFFD2EEE5,
        messages: [
          ChatMessage(
            text: 'I’ll bring the camera 📷',
            mine: true,
            at: now.subtract(const Duration(hours: 3)),
          ),
        ],
      ),
      Conversation(
        id: 'noah',
        name: 'Noah Williams',
        color: 0xFFE9DDF4,
        messages: [
          ChatMessage(
            text: 'See you on the trail tomorrow.',
            mine: false,
            at: now.subtract(const Duration(days: 1)),
          ),
        ],
      ),
    ];
  }
}
