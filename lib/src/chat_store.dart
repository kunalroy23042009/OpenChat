import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ai/ai_service.dart';

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
  Map<String, dynamic> toJson() => {
    'text': text,
    'mine': mine,
    'at': at.toIso8601String(),
    'clientId': clientId,
    'status': status,
    'envelopeId': envelopeId,
  };
  factory SecureMessage.fromJson(Map<String, dynamic> json) => SecureMessage(
    text: json['text'] as String,
    mine: json['mine'] as bool,
    at: DateTime.parse(json['at'] as String),
    clientId: json['clientId'] as String? ?? '',
    status: json['status'] as String? ?? 'sent',
    envelopeId: json['envelopeId'] as String?,
  );
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
    messages: (json['messages'] as List)
        .map((m) => ChatMessage.fromJson(Map<String, dynamic>.from(m as Map)))
        .toList(),
  );
}

/// Demo data only. Never use this plaintext storage for production messages.
class ChatStore extends ChangeNotifier {
  ChatStore(this.preferences) {
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
      chat.messages.add(ChatMessage(text: reply, mine: false, at: DateTime.now()));
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
          text: 'Hello! I am $name inside OpenChat. Ask me anything or configure my API key in Settings → AI Providers.',
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
        conversations[existing] = Conversation(
          id: conversations[existing].id,
          name: conversations[existing].name,
          color: conversations[existing].color,
          messages: list
              .map((m) => ChatMessage(text: m.text, mine: m.mine, at: m.at))
              .toList(),
          unread: conversations[existing].unread,
          muted: conversations[existing].muted,
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
  }) async {
    final key = _secureKey(accountId, peerId);
    final saved = preferences.getString(key);
    List<SecureMessage> messages;
    if (saved == null) {
      messages = [];
    } else {
      try {
        messages = (jsonDecode(saved) as Map)['messages']
            .map((m) => SecureMessage.fromJson(Map<String, dynamic>.from(m)))
            .toList();
      } catch (_) {
        messages = [];
      }
    }
    // Envelope ids are unique per sender; skip redelivered rows so a
    // retried inbox can never duplicate a stored message.
    if (envelopeId != null &&
        messages.any((m) => m.envelopeId == envelopeId)) {
      return;
    }
    messages.add(
      SecureMessage(
        text: text,
        mine: mine,
        at: DateTime.now(),
        clientId: clientId,
        envelopeId: envelopeId,
      ),
    );
    // Keep only last 1000 messages per conversation
    if (messages.length > 1000) {
      messages = messages.sublist(messages.length - 1000);
    }
    final ok = await preferences.setString(
      key,
      jsonEncode({'messages': messages.map((m) => m.toJson()).toList()}),
    );
    if (!ok) throw StateError('Secure save failed');
    // Also update the in-memory Conversation if it exists
    final secureId = _secureId(accountId, peerId);
    final idx = conversations.indexWhere((c) => c.id == secureId);
    if (idx >= 0) {
      conversations[idx] = Conversation(
        id: conversations[idx].id,
        name: conversations[idx].name,
        color: conversations[idx].color,
        messages: messages
            .map((m) => ChatMessage(text: m.text, mine: m.mine, at: m.at))
            .toList(),
        unread: conversations[idx].unread,
        muted: conversations[idx].muted,
      );
    }
    notifyListeners();
  }

  List<SecureMessage> getSecureConversation(String accountId, String peerId) {
    final key = _secureKey(accountId, peerId);
    final saved = preferences.getString(key);
    if (saved == null) return [];
    try {
      final list = (jsonDecode(saved) as Map)['messages'] as List;
      return list
          .map((m) => SecureMessage.fromJson(Map<String, dynamic>.from(m)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  bool hasSecureEnvelope(String accountId, String peerId, String envelopeId) {
    if (envelopeId.isEmpty) return false;
    return getSecureConversation(
      accountId,
      peerId,
    ).any((m) => m.envelopeId == envelopeId);
  }

  /// Updates the sender-side tick for a local echo. No-op when the row is
  /// missing (e.g. cleared history).
  Future<void> updateSecureStatus(
    String accountId,
    String peerId,
    String clientId,
    String status,
  ) async {
    if (clientId.isEmpty) return;
    final key = _secureKey(accountId, peerId);
    final saved = preferences.getString(key);
    if (saved == null) return;
    try {
      final messages = ((jsonDecode(saved) as Map)['messages'] as List)
          .map((m) => SecureMessage.fromJson(Map<String, dynamic>.from(m)))
          .toList();
      var changed = false;
      for (var i = 0; i < messages.length; i++) {
        final m = messages[i];
        if (m.mine && m.clientId == clientId && m.status != status) {
          messages[i] = SecureMessage(
            text: m.text,
            mine: m.mine,
            at: m.at,
            clientId: m.clientId,
            status: status,
            envelopeId: m.envelopeId,
          );
          changed = true;
        }
      }
      if (!changed) return;
      await preferences.setString(
        key,
        jsonEncode({'messages': messages.map((m) => m.toJson()).toList()}),
      );
      notifyListeners();
    } catch (_) {}
  }

  static const _failPrefix = 'openchat.envelopeFails.v1.';

  int envelopeFailCount(String envelopeId) =>
      preferences.getInt('$_failPrefix$envelopeId') ?? 0;

  Future<void> recordEnvelopeFailure(String envelopeId) =>
      preferences.setInt(
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
