import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai/ai_service.dart';
import 'media/media_message.dart';

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
  static const deleteWindow = Duration(hours: 1);

  bool canDeleteForEveryone(DateTime now) => mine && clientId.isNotEmpty &&
      !hidden && !parseMessageBody(text).isTombstone &&
      now.difference(at) >= Duration.zero && now.difference(at) <= deleteWindow;

  SecureMessage withBody(String body, {bool? hidden}) => SecureMessage(
    text: body, mine: mine, at: at, clientId: clientId, status: status,
    envelopeId: envelopeId, peerClientId: peerClientId,
    deliveredAt: deliveredAt, readAt: readAt, hidden: hidden ?? this.hidden,
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
    this.isAi = false,
    this.aiProvider,
    this.aiModel,
    this.archived = false,
    this.pinned = false,
    this.favourite = false,
    this.locked = false,
  });
  final String id;
  final String name;
  final int color;
  final List<ChatMessage> messages;
  int unread;
  bool muted;
  final bool isAi;
  final String? aiProvider;
  final String? aiModel;

  /// Organization flags. All default false so every historical row parses.
  bool archived;
  bool pinned;
  bool favourite;
  bool locked;
  bool isTyping = false;
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
    'isAi': isAi,
    'aiProvider': aiProvider,
    'aiModel': aiModel,
    'archived': archived,
    'pinned': pinned,
    'favourite': favourite,
    'locked': locked,
    'messages': messages.map((m) => m.toJson()).toList(),
  };
  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
    id: json['id'] as String,
    name: json['name'] as String,
    color: json['color'] as int,
    unread: json['unread'] as int,
    muted: json['muted'] as bool? ?? false,
    isAi: json['isAi'] as bool? ?? false,
    aiProvider: json['aiProvider'] as String?,
    aiModel: json['aiModel'] as String?,
    archived: json['archived'] as bool? ?? false,
    pinned: json['pinned'] as bool? ?? false,
    favourite: json['favourite'] as bool? ?? false,
    locked: json['locked'] as bool? ?? false,
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

  ChatStore(this.preferences, {bool purgeDemoSeeds = false}) {
    AiService.instance.init(preferences);
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
    if (purgeDemoSeeds &&
        conversations.any((c) => demoSeedIds.contains(c.id))) {
      conversations.removeWhere((c) => demoSeedIds.contains(c.id));
      _save();
    }
  }
  static const storageKey = 'openchat.demo.v1';
  final SharedPreferences preferences;
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

  Future<void> send(Conversation chat, String text) async {
    final clean = text.trim();
    if (clean.isEmpty || clean.length > 4000) return;
    chat.messages.add(ChatMessage(text: clean, mine: true, at: DateTime.now()));
    conversations.remove(chat);
    conversations.insert(0, chat);
    await _save();

    if (chat.isAi && chat.aiProvider != null) {
      _triggerAiReply(chat, clean);
    }
  }

  Future<void> _triggerAiReply(Conversation chat, String prompt) async {
    chat.isTyping = true;
    notifyListeners();

    try {
      final provider = AiProviderType.values.firstWhere(
        (p) => p.name == chat.aiProvider,
        orElse: () => AiProviderType.openai,
      );
      final reply = await AiService.instance.generateReply(
        providerType: provider,
        userPrompt: prompt,
        history: chat.messages,
      );
      chat.messages.add(
        ChatMessage(text: reply, mine: false, at: DateTime.now()),
      );
    } catch (e) {
      chat.messages.add(
        ChatMessage(
          text: 'Error generating AI reply: $e',
          mine: false,
          at: DateTime.now(),
        ),
      );
    } finally {
      chat.isTyping = false;
      await _save();
    }
  }

  Future<Conversation> createAiChat({
    required String name,
    required String provider,
    required int color,
    String? model,
  }) async {
    final chat = Conversation(
      id: 'ai_${provider}_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      color: color,
      isAi: true,
      aiProvider: provider,
      aiModel: model,
      messages: [
        ChatMessage(
          text:
              'Hello! I am $name inside OpenChat. Ask me anything or configure my API key in Settings → AI Providers.',
          mine: false,
          at: DateTime.now(),
        ),
      ],
    );
    conversations.insert(0, chat);
    await _save();
    return chat;
  }

  Future<void> markRead(Conversation chat) async {
    chat.unread = 0;
    await _save();
  }

  Future<void> toggleMute(Conversation chat) async {
    chat.muted = !chat.muted;
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
    final saved = preferences.getString(key);
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
          archived: current.archived,
          pinned: current.pinned,
          favourite: current.favourite,
          locked: current.locked,
        );
      }
    } catch (_) {
      // Corrupt or missing secure data; ignore.
    }
  }

  static String _secureId(String accountId, String peerId) =>
      '_secure_$accountId-$peerId';

  static String _secureKey(String accountId, String peerId) =>
      '$_securePrefix$accountId-$peerId';

  DateTime? lastSecureMessageTime(String accountId, String peerId) {
    final key = _secureKey(accountId, peerId);
    final saved = preferences.getString(key);
    if (saved == null) return null;
    try {
      final data = jsonDecode(saved) as Map<String, dynamic>;
      final list = (data['messages'] as List);
      if (list.isEmpty) return null;
      return DateTime.parse((list.last as Map)['at'] as String);
    } catch (_) {
      return null;
    }
  }

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
          (!mine && peerClientId != null && peerClientId.isNotEmpty &&
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
      for (final control in messages.where((m) => parseMessageBody(m.text).isDelete || parseMessageBody(m.text).isEdit)) {
        final body = parseMessageBody(control.text);
        final target = body.target;
        if (target == null || target.isEmpty) continue;
        final window = body.isDelete ? SecureMessage.deleteWindow : SecureMessage.editWindow;
        for (var i = 0; i < messages.length; i++) {
          final m = messages[i];
          final id = m.mine ? m.clientId : m.peerClientId;
          final age = control.at.difference(m.at);
          if (m.mine == control.mine && id == target &&
              age >= Duration.zero && age <= window) {
            final original = parseMessageBody(m.text);
            if (original.isControl) continue;
            if (body.isDelete) {
              messages[i] = m.withBody(encodeTombstoneBody());
            } else if (original.isEditable) {
              // Media/poll bodies reject correction; the control is kept
              // for idempotency but changes nothing.
              messages[i] = m.withBody(original.editedBody(body.text));
            }
          }
        }
      }
      // Stable chronological ordering, including equal timestamps.
      final ordered = messages.asMap().entries.toList()..sort((a, b) {
        final time = a.value.at.compareTo(b.value.at);
        return time == 0 ? a.key.compareTo(b.key) : time;
      });
      await _writeSecureMessages(accountId, peerId, ordered.map((e) => e.value).toList());
    });
  }

  List<SecureMessage> _readSecureMessages(String key) {
    final saved = preferences.getString(key);
    if (saved == null) return [];
    final rows = (jsonDecode(saved) as Map)['messages'] as List;
    return rows.map((row) => SecureMessage.fromJson(Map<String, dynamic>.from(row as Map))).toList();
  }

  Future<void> _writeSecureMessages(String accountId, String peerId, List<SecureMessage> messages) async {
    final ok = await preferences.setString(_secureKey(accountId, peerId),
      jsonEncode({'messages': messages.map((m) => m.toJson()).toList()}));
    if (!ok) throw StateError('Secure save failed');
    _syncSecureConversation(accountId, peerId,
      messages.where((m) {
        if (m.hidden) return false;
        final kind = parseMessageBody(m.text);
        // Ballots stay for tallies; tombstones render. Delete, reaction
        // and edit markers are applied-then-dropped transport only.
        return !kind.isDelete && !kind.isReact && !kind.isEdit;
      }).toList());
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
      archived: current.archived,
      pinned: current.pinned,
      favourite: current.favourite,
      locked: current.locked,
    );
  }

  List<SecureMessage> getSecureConversation(String accountId, String peerId) {
    final key = _secureKey(accountId, peerId);
    final saved = preferences.getString(key);
    if (saved == null) return [];
    try {
      return _readSecureMessages(key)
          .where((m) {
            if (m.hidden) return false;
            final kind = parseMessageBody(m.text);
            return !kind.isDelete && !kind.isReact && !kind.isEdit;
          })
          .toList();
    } catch (_) {
      storageWarning = 'Saved encrypted-chat history could not be read. The original data has been preserved.';
      return [];
    }
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
      final saved = preferences.getString(key);
      if (saved == null) return;
        final messages = _readSecureMessages(key);
        var changed = false;
        for (var i = 0; i < messages.length; i++) {
          final m = messages[i];
          if (m.mine && m.clientId == clientId) {
            const ranks = {'sent': 0, 'delivered': 1, 'read': 2};
            if (!ranks.containsKey(status)) continue;
            final nextStatus = ranks[status]! >= (ranks[m.status] ?? 0) ? status : m.status;
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
      final saved = preferences.getString(key);
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

  static String _starKey(String accountId, String peerId) =>
      'openchat.stars.v1.$accountId-$peerId';
  static String _pinKey(String accountId, String peerId) =>
      'openchat.pins.v1.$accountId-$peerId';

  Future<Set<String>> secureStars(String accountId, String peerId) async {
    final list = preferences.getStringList(
      _starKey(accountId, peerId),
    );
    final available = getSecureConversation(accountId, peerId)
        .where((m) => !parseMessageBody(m.text).isTombstone).map((m) => m.ref).toSet();
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
        .where((m) => !parseMessageBody(m.text).isTombstone).map((m) => m.ref).toSet();
    return (preferences.getStringList(_pinKey(accountId, peerId)) ?? [])
        .where(available.contains).toList();
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
    if (pins.contains(ref)) { pinned = true; return; }
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
    if (saved == null || saved.isEmpty) return {};
    try {
      final decoded = jsonDecode(saved) as Map<String, dynamic>;
      return {
        for (final entry in decoded.entries)
          entry.key: {
            for (final vote in (entry.value as Map).entries)
              vote.key.toString(): vote.value.toString(),
          },
      };
    } catch (_) {
      return {};
    }
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
        if (!own) {
          votes.remove(emoji);
        } else if (other) {
          votes[emoji] = mine ? 'peer' : 'mine';
        } else {
          votes.remove(emoji);
        }
      } else if (!own && !other) {
        votes[emoji] = mine ? 'mine' : 'peer';
      } else if (own != other) {
        votes[emoji] = 'both';
      }
      if (votes.isEmpty) {
        all.remove(ref);
      } else {
        all[ref] = votes;
      }
      await preferences.setString(_reactKey(accountId, peerId), jsonEncode(all));
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

  static String _unreadKey(String accountId) =>
      'openchat.unread.v1.$accountId';

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
