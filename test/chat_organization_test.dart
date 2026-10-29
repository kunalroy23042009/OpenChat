import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_chat/src/chat_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<ChatStore> freshStore() async {
  SharedPreferences.setMockInitialValues({});
  return ChatStore(await SharedPreferences.getInstance());
}

void main() {
  test('manual unread stays synchronized across both chat lists and reopening', () async {
    final store = await freshStore();
    final chat = Conversation(id: '_secure_account-peer', name: 'Peer', color: 1, messages: []);
    store.conversations.add(chat);
    await store.setMarkedUnread(chat.id, true);
    expect(store.secureUnread('account', 'peer'), isTrue);
    await store.setSecureUnread('account', 'peer', false);
    expect(chat.markedUnread, isFalse);
    await store.setSecureUnread('account', 'peer', true);
    expect(chat.markedUnread, isTrue);
    await store.markRead(chat);
    expect(store.secureUnread('account', 'peer'), isFalse);
    final reloaded = ChatStore(await SharedPreferences.getInstance());
    expect(reloaded.conversations.firstWhere((c) => c.id == chat.id).markedUnread, isFalse);
  });

  test('organization flags default false on legacy rows', () {
    final chat = Conversation.fromJson({
      'id': 'x',
      'name': 'X',
      'color': 1,
      'unread': 0,
      'messages': [],
    });
    expect(chat.archived, isFalse);
    expect(chat.pinned, isFalse);
    expect(chat.favourite, isFalse);
    expect(chat.locked, isFalse);
  });

  test('organization flags round-trip', () {
    final chat = Conversation(
      id: 'x',
      name: 'X',
      color: 1,
      messages: [],
      archived: true,
      pinned: true,
      favourite: true,
      locked: true,
    );
    final back = Conversation.fromJson(chat.toJson());
    expect(back.archived, isTrue);
    expect(back.pinned, isTrue);
    expect(back.favourite, isTrue);
    expect(back.locked, isTrue);
  });

  test('archive, pin, favourite, and lock toggles persist', () async {
    final store = await freshStore();
    final chat = await store.create('Pilot');
    await store.setArchived(chat.id, true);
    await store.setPinned(chat.id, true);
    await store.setFavourite(chat.id, true);
    await store.setLocked(chat.id, true);

    final reloaded = ChatStore(await SharedPreferences.getInstance());
    final back = reloaded.conversations.firstWhere((c) => c.id == chat.id);
    expect(back.archived, isTrue);
    expect(back.pinned, isTrue);
    expect(back.favourite, isTrue);
    expect(back.locked, isTrue);
  });

  test('production purge removes seeds and legacy dialog chats', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    // Saved state: a legacy name-only dialog chat (numeric id) next to a
    // real encrypted chat. Both kinds of fictional chat must go; the real
    // one stays.
    final legacy = Conversation(
      id: '1729030000000000',
      name: 'Old dialog chat',
      color: 0xFFDBE6FF,
      messages: [],
    );
    final real = Conversation(
      id: '_secure_me-6b2f4c9e',
      name: 'Real chat',
      color: 0xFFDDE5FF,
      messages: [],
    );
    await preferences.setString(
      ChatStore.storageKey,
      jsonEncode([legacy.toJson(), real.toJson()]),
    );
    final store = ChatStore(preferences, purgeDemoSeeds: true);
    final ids = store.conversations.map((c) => c.id).toSet();
    expect(ids, isNot(contains('maya')));
    expect(ids, isNot(contains('leo')));
    expect(ids, isNot(contains('aisha')));
    expect(ids, isNot(contains('noah')));
    expect(ids, isNot(contains(legacy.id)));
    expect(ids, contains(real.id));
  });
}
