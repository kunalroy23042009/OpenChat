import 'package:flutter_test/flutter_test.dart';
import 'package:open_chat/src/chat_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<ChatStore> freshStore() async {
  SharedPreferences.setMockInitialValues({});
  return ChatStore(await SharedPreferences.getInstance());
}

void main() {
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

  test('production purge removes only fictional seeds', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final store = ChatStore(preferences, purgeDemoSeeds: true);
    final ids = store.conversations.map((c) => c.id).toSet();
    expect(ids, isNot(contains('maya')));
    expect(ids, isNot(contains('leo')));
    expect(ids, isNot(contains('aisha')));
    expect(ids, isNot(contains('noah')));

    final kept = await store.create('Mine');
    final reloaded = ChatStore(preferences, purgeDemoSeeds: true);
    expect(reloaded.conversations.any((c) => c.id == kept.id), isTrue);
  });
}
