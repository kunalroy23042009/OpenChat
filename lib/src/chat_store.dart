import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  SecureMessage({required this.text, required this.mine, required this.at});
  final String text;
  final bool mine;
  final DateTime at;
  Map<String, dynamic> toJson() => {
    'text': text,
    'mine': mine,
    'at': at.toIso8601String(),
  };
  factory SecureMessage.fromJson(Map<String, dynamic> json) => SecureMessage(
    text: json['text'] as String,
    mine: json['mine'] as bool,
    at: DateTime.parse(json['at'] as String),
  );
}

class Conversation {
  Conversation({
    required this.id,
    required this.name,
    required this.color,
    required this.messages,
    this.unread = 0,
  });
  final String id;
  final String name;
  final int color;
  final List<ChatMessage> messages;
  int unread;
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
    'messages': messages.map((m) => m.toJson()).toList(),
  };
  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
    id: json['id'] as String,
    name: json['name'] as String,
    color: json['color'] as int,
    unread: json['unread'] as int,
    messages: (json['messages'] as List)
        .map((m) => ChatMessage.fromJson(Map<String, dynamic>.from(m as Map)))
        .toList(),
  );
}

/// Demo data only. Never use this plaintext storage for production messages.
class ChatStore extends ChangeNotifier {
  ChatStore(this.preferences) {
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
  }

  Future<void> markRead(Conversation chat) async {
    chat.unread = 0;
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
          messages: list.cast<ChatMessage>(),
          unread: conversations[existing].unread,
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
    messages.add(SecureMessage(text: text, mine: mine, at: DateTime.now()));
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
      );
    }
    notifyListeners();
  }

  List<ChatMessage> getSecureConversation(String accountId, String peerId) {
    final key = _secureKey(accountId, peerId);
    final saved = preferences.getString(key);
    if (saved == null) return [];
    try {
      final list = (jsonDecode(saved) as Map)['messages'] as List;
      return list
          .map((m) => ChatMessage.fromJson(Map<String, dynamic>.from(m)))
          .toList();
    } catch (_) {
      return [];
    }
  }

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
