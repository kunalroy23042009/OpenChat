import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_chat/src/chat_store.dart';
import 'package:open_chat/src/media/media_message.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<ChatStore> secureStore() async {
  SharedPreferences.setMockInitialValues({});
  return ChatStore(await SharedPreferences.getInstance());
}

void main() {
  test(
    'reaction controls resolve across devices, survive restart and dedupe',
    () async {
      final store = await secureStore();
      final at = DateTime.utc(2026, 10, 12);
      await store.addSecureMessage(
        'alice',
        'bob',
        'hello',
        mine: true,
        clientId: 'm',
        at: at,
      );
      await store.addSecureMessage(
        'bob',
        'alice',
        'hello',
        mine: false,
        peerClientId: 'm',
        envelopeId: 'msg',
        at: at,
      );
      final reaction = encodeReactBody('alice:m', '❤️');
      await store.addSecureMessage(
        'bob',
        'alice',
        reaction,
        mine: true,
        clientId: 'r',
        at: at.add(const Duration(seconds: 1)),
      );
      await store.addSecureMessage(
        'alice',
        'bob',
        reaction,
        mine: false,
        envelopeId: 'reaction',
        peerClientId: 'r',
        at: at.add(const Duration(seconds: 1)),
      );
      final restarted = ChatStore(store.preferences);
      expect(restarted.secureReactions('alice', 'bob')['out:m'], {
        '❤️': 'peer',
      });
      expect(restarted.secureReactions('bob', 'alice')['in:m'], {'❤️': 'mine'});
      expect(restarted.hasSecureEnvelope('alice', 'bob', 'reaction'), isTrue);
      await restarted.addSecureMessage(
        'alice',
        'bob',
        reaction,
        mine: false,
        envelopeId: 'reaction',
        peerClientId: 'r',
      );
      expect(restarted.secureReactions('alice', 'bob')['out:m'], {
        '❤️': 'peer',
      });
      await restarted.addSecureMessage(
        'alice',
        'bob',
        encodeReactBody('alice:m', '👍'),
        mine: false,
        envelopeId: 'replacement',
        at: at.add(const Duration(seconds: 2)),
      );
      expect(restarted.secureReactions('alice', 'bob')['out:m'], {
        '👍': 'peer',
      });
      await restarted.addSecureMessage(
        'alice',
        'bob',
        encodeReactBody('alice:m', '👍', remove: true),
        mine: false,
        envelopeId: 'remove',
        at: at.add(const Duration(seconds: 3)),
      );
      expect(restarted.secureReactions('alice', 'bob'), isEmpty);
    },
  );

  test(
    'a reaction cannot target the wrong author with a colliding client id',
    () async {
      final store = await secureStore();
      await store.addSecureMessage(
        'me',
        'peer',
        'ours',
        mine: true,
        clientId: 'same',
      );
      await store.addSecureMessage(
        'me',
        'peer',
        'theirs',
        mine: false,
        peerClientId: 'same',
      );
      await store.addSecureMessage(
        'me',
        'peer',
        encodeReactBody('peer:same', '👍'),
        mine: false,
        envelopeId: 'reaction',
      );
      expect(store.secureReactions('me', 'peer'), {
        'in:same': {'👍': 'peer'},
      });
    },
  );
  final sentAt = DateTime.utc(2026, 10, 12, 12);

  test(
    'retraction is author-scoped and keeps position, ids and timestamps',
    () async {
      final store = await secureStore();
      await store.addSecureMessage(
        'me',
        'peer',
        'mine',
        mine: true,
        clientId: 'shared',
        at: sentAt,
      );
      await store.addSecureMessage(
        'me',
        'peer',
        'theirs',
        mine: false,
        peerClientId: 'shared',
        envelopeId: 'e1',
        at: sentAt,
      );
      await store.addSecureMessage(
        'me',
        'peer',
        'later',
        mine: true,
        clientId: 'later',
        at: sentAt.add(const Duration(minutes: 2)),
      );
      await store.addSecureMessage(
        'me',
        'peer',
        encodeDeleteBody('shared'),
        mine: false,
        envelopeId: 'delete',
        at: sentAt.add(const Duration(minutes: 3)),
      );
      final messages = store.getSecureConversation('me', 'peer');
      expect(messages, hasLength(3));
      expect(messages.first.text, 'mine');
      expect(parseMessageBody(messages[1].text).isTombstone, isTrue);
      expect(messages[1].at, sentAt);
      expect(messages[1].envelopeId, 'e1');
      expect(messages[1].peerClientId, 'shared');
      expect(messages.last.text, 'later');
      expect(store.hasSecureEnvelope('me', 'peer', 'delete'), isTrue);
    },
  );

  test(
    'out-of-order delete persists until the matching author message arrives',
    () async {
      final store = await secureStore();
      await store.addSecureMessage(
        'me',
        'alice',
        encodeDeleteBody('original'),
        mine: false,
        envelopeId: 'delete',
        at: sentAt.add(const Duration(minutes: 1)),
      );
      await store.addSecureMessage(
        'me',
        'bob',
        'other chat',
        mine: false,
        peerClientId: 'original',
        at: sentAt,
      );
      await store.addSecureMessage(
        'me',
        'alice',
        'original content',
        mine: false,
        peerClientId: 'original',
        at: sentAt,
      );
      expect(
        parseMessageBody(store.getSecureConversation('me', 'alice').single.text)
            .isTombstone,
        isTrue,
      );
      expect(
        store.getSecureConversation('me', 'bob').single.text,
        'other chat',
      );
    },
  );

  test('expired secure messages are hidden and permanently purged', () async {
    final store = await secureStore();
    await store.addSecureMessage(
      'me',
      'peer',
      'keep',
      mine: true,
      clientId: 'active',
    );
    // Simulate a history row that crossed its expiry while the app was closed.
    final key = 'openchat.secure.v1.me-peer';
    final payload =
        jsonDecode(store.preferences.getString(key)!) as Map<String, dynamic>;
    (payload['messages'] as List).add(
      SecureMessage(
        text: encodeExpiringBody('gone', DateTime.utc(2000)),
        mine: true,
        at: DateTime.utc(1999),
        clientId: 'expired',
      ).toJson(),
    );
    await store.preferences.setString(key, jsonEncode(payload));

    expect(store.getSecureConversation('me', 'peer').map((m) => m.text), [
      'keep',
    ]);
    expect(await store.purgeExpiredSecureMessages('me', 'peer'), 1);
    final restarted = ChatStore(store.preferences);
    expect(restarted.getSecureConversation('me', 'peer').map((m) => m.text), [
      'keep',
    ]);
  });

  test('deletes outside 60 hours or before the original are ignored', () async {
    final store = await secureStore();
    await store.addSecureMessage(
      'me',
      'peer',
      'keep',
      mine: false,
      peerClientId: 'x',
      at: sentAt,
    );
    for (final minutes in [-1, 3601]) {
      await store.addSecureMessage(
        'me',
        'peer',
        encodeDeleteBody('x'),
        mine: false,
        envelopeId: '$minutes',
        at: sentAt.add(Duration(minutes: minutes)),
      );
    }
    expect(store.getSecureConversation('me', 'peer').single.text, 'keep');
  });

  test(
    'delete for me erases body but retains deduplication after restart',
    () async {
      final store = await secureStore();
      await store.addSecureMessage(
        'me',
        'peer',
        'sensitive content',
        mine: false,
        peerClientId: 'x',
        envelopeId: 'env',
      );
      final ref = store.getSecureConversation('me', 'peer').single.ref;
      await store.toggleSecureStar('me', 'peer', ref);
      await store.pinSecureMessage('me', 'peer', ref);
      expect(await store.removeSecureMessage('me', 'peer', ref), isTrue);
      final restarted = ChatStore(store.preferences);
      await restarted.addSecureMessage(
        'me',
        'peer',
        'sensitive content',
        mine: false,
        peerClientId: 'x',
        envelopeId: 'env',
      );
      expect(restarted.getSecureConversation('me', 'peer'), isEmpty);
      expect(restarted.hasSecureEnvelope('me', 'peer', 'env'), isTrue);
      expect(await restarted.secureStars('me', 'peer'), isEmpty);
      expect(await restarted.securePins('me', 'peer'), isEmpty);
      expect(
        store.preferences.getString('openchat.secure.v1.me-peer'),
        isNot(contains('sensitive content')),
      );
    },
  );

  test(
    'a corrupt history is preserved rather than overwritten on append',
    () async {
      final store = await secureStore();
      const key = 'openchat.secure.v1.me-peer';
      await store.preferences.setString(key, '{corrupt');
      await expectLater(
        store.addSecureMessage('me', 'peer', 'new', mine: true),
        throwsFormatException,
      );
      expect(store.preferences.getString(key), '{corrupt');
    },
  );

  test(
    'appending beyond 1000 messages does not silently prune history',
    () async {
      final store = await secureStore();
      await store.preferences.setString(
        'openchat.secure.v1.me-peer',
        jsonEncode({
          'messages': List.generate(
            1000,
            (i) => SecureMessage(
              text: 'message $i',
              mine: true,
              clientId: '$i',
              at: sentAt,
            ).toJson(),
          ),
        }),
      );
      await store.addSecureMessage(
        'me',
        'peer',
        'new',
        mine: true,
        clientId: '1000',
        at: sentAt.add(const Duration(seconds: 1)),
      );
      final history = store.getSecureConversation('me', 'peer');
      expect(history, hasLength(1001));
      expect(history.first.text, 'message 0');
    },
  );

  test('receipts never regress and survive a retraction', () async {
    final store = await secureStore();
    await store.addSecureMessage(
      'me',
      'peer',
      'text',
      mine: true,
      clientId: 'x',
      at: sentAt,
    );
    final time = sentAt.toIso8601String();
    await store.updateSecureStatus(
      'me',
      'peer',
      'x',
      'read',
      deliveredAt: time,
      readAt: time,
    );
    await store.updateSecureStatus('me', 'peer', 'x', 'sent');
    await store.addSecureMessage(
      'me',
      'peer',
      encodeDeleteBody('x'),
      mine: true,
      clientId: 'delete',
      at: sentAt.add(const Duration(minutes: 1)),
    );
    final msg = store.getSecureConversation('me', 'peer').single;
    expect(msg.status, 'read');
    expect(msg.deliveredAt, time);
    expect(msg.readAt, time);
    expect(msg.clientId, 'x');
  });
  test(
    'concurrent pins stop at three without evicting existing pins',
    () async {
      final store = await secureStore();
      for (var i = 0; i < 4; i++) {
        await store.addSecureMessage(
          'me',
          'peer',
          '$i',
          mine: true,
          clientId: '$i',
        );
      }
      final refs = store
          .getSecureConversation('me', 'peer')
          .map((m) => m.ref)
          .toList();
      final results = await Future.wait(
        refs.map((ref) => store.pinSecureMessage('me', 'peer', ref)),
      );
      expect(results, [true, true, true, false]);
      expect(await store.securePins('me', 'peer'), refs.take(3));
      await Future.wait(
        refs.map((ref) => store.toggleSecureStar('me', 'peer', ref)),
      );
      expect(await store.secureStars('me', 'peer'), refs.toSet());
    },
  );

  test('edits replace in place inside 15 minutes, keep receipts', () async {
    final store = await secureStore();
    final sentAt = DateTime.utc(2026, 10, 12, 12);
    await store.addSecureMessage(
      'me',
      'peer',
      'Helow',
      mine: true,
      clientId: 'x',
      at: sentAt,
    );
    await store.updateSecureStatus(
      'me',
      'peer',
      'x',
      'read',
      deliveredAt: sentAt.toIso8601String(),
      readAt: sentAt.toIso8601String(),
    );
    await store.addSecureMessage(
      'me',
      'peer',
      encodeEditBody('x', 'Hello'),
      mine: true,
      clientId: 'edit-1',
      at: sentAt.add(const Duration(minutes: 5)),
    );
    final messages = store.getSecureConversation('me', 'peer');
    expect(messages, hasLength(1));
    expect(messages.single.text, 'Hello');
    expect(messages.single.clientId, 'x');
    expect(messages.single.status, 'read');
    expect(
      messages.single.canEdit(sentAt.add(const Duration(minutes: 10))),
      isTrue,
    );
    expect(
      messages.single.canEdit(sentAt.add(const Duration(minutes: 16))),
      isFalse,
    );
  });

  test('late, early, foreign and non-text edits are ignored', () async {
    final store = await secureStore();
    final sentAt = DateTime.utc(2026, 10, 12, 12);
    await store.addSecureMessage(
      'me',
      'peer',
      'Keep',
      mine: false,
      peerClientId: 'x',
      at: sentAt,
    );
    await store.addSecureMessage(
      'me',
      'peer',
      encodeImageBody('a/b.jpg', 'cap'),
      mine: false,
      peerClientId: 'img',
      at: sentAt,
    );
    await store.addSecureMessage(
      'me',
      'peer',
      encodeEditBody('x', 'Changed'),
      mine: false,
      envelopeId: 'late',
      at: sentAt.add(const Duration(minutes: 16)),
    );
    await store.addSecureMessage(
      'me',
      'peer',
      encodeEditBody('x', 'Changed'),
      mine: true,
      clientId: 'foreign',
      at: sentAt.add(const Duration(minutes: 1)),
    );
    await store.addSecureMessage(
      'me',
      'peer',
      encodeEditBody('img', 'new cap'),
      mine: false,
      envelopeId: 'imgedit',
      at: sentAt.add(const Duration(minutes: 1)),
    );
    final texts = store
        .getSecureConversation('me', 'peer')
        .map((m) => m.text)
        .toList();
    expect(texts.first, 'Keep');
    expect(parseMessageBody(texts[1]).text, 'cap');
  });

  test('reactions converge on explicit state, never flap', () async {
    final store = await secureStore();
    await store.applySecureReaction(
      'me',
      'peer',
      'ref',
      '❤️',
      mine: true,
      remove: false,
    );
    await store.applySecureReaction(
      'me',
      'peer',
      'ref',
      '❤️',
      mine: false,
      remove: false,
    );
    expect(store.secureReactions('me', 'peer'), {
      'ref': {'❤️': 'both'},
    });
    // Redelivery of the same state changes nothing.
    await store.applySecureReaction(
      'me',
      'peer',
      'ref',
      '❤️',
      mine: false,
      remove: false,
    );
    expect(store.secureReactions('me', 'peer'), {
      'ref': {'❤️': 'both'},
    });
    await store.applySecureReaction(
      'me',
      'peer',
      'ref',
      '❤️',
      mine: true,
      remove: true,
    );
    expect(store.secureReactions('me', 'peer'), {
      'ref': {'❤️': 'peer'},
    });
    await store.applySecureReaction(
      'me',
      'peer',
      'ref',
      '❤️',
      mine: false,
      remove: true,
    );
    expect(store.secureReactions('me', 'peer'), isEmpty);
    expect(store.secureReactions('me', 'nobody'), isEmpty);
  });

  test('drafts and unread flags round-trip per peer', () async {
    final store = await secureStore();
    expect(store.secureDraft('me', 'peer'), isEmpty);
    expect(store.secureUnread('me', 'peer'), isFalse);
    await store.setSecureDraft('me', 'peer', 'half-typed');
    await store.setSecureUnread('me', 'peer', true);
    expect(store.secureDraft('me', 'peer'), 'half-typed');
    expect(store.secureUnread('me', 'peer'), isTrue);
    expect(store.secureDraft('me', 'other'), isEmpty);
    await store.setSecureDraft('me', 'peer', '');
    await store.setSecureUnread('me', 'peer', false);
    expect(store.secureDraft('me', 'peer'), isEmpty);
    expect(store.secureUnread('me', 'peer'), isFalse);
  });

  test('self-notes chat is local-only and reusable', () async {
    final store = await secureStore();
    final first = await store.ensureSelfChat();
    expect(first.id, ChatStore.selfChatId);
    await store.send(first, 'note to self');
    expect((await store.ensureSelfChat()).messages.last.text, 'note to self');
  });

  test('legacy rows without tick fields parse with safe defaults', () {
    final msg = SecureMessage.fromJson({
      'text': 'hello',
      'mine': true,
      'at': DateTime.utc(2026, 1, 1).toIso8601String(),
    });
    expect(msg.clientId, isEmpty);
    expect(msg.status, 'sent');
    expect(msg.envelopeId, isNull);
  });

  test('tick fields round-trip', () {
    final msg = SecureMessage(
      text: 'hi',
      mine: true,
      at: DateTime.utc(2026, 1, 2),
      clientId: 'abc-123',
      status: 'delivered',
      envelopeId: 'env-1',
    );
    final back = SecureMessage.fromJson(msg.toJson());
    expect(back.clientId, 'abc-123');
    expect(back.status, 'delivered');
    expect(back.envelopeId, 'env-1');
    expect(back.text, 'hi');
    expect(back.mine, isTrue);
  });

  test('incoming messages keep default tick state', () {
    final msg = SecureMessage(
      text: 'hey',
      mine: false,
      at: DateTime.utc(2026, 1, 3),
      envelopeId: 'env-9',
    );
    expect(msg.status, 'sent');
    expect(msg.clientId, isEmpty);
  });

  test('concurrent sends append instead of overwriting history', () async {
    final store = await secureStore();

    await Future.wait([
      store.addSecureMessage('me', 'peer', 'first', mine: true, clientId: '1'),
      store.addSecureMessage('me', 'peer', 'second', mine: true, clientId: '2'),
      store.addSecureMessage(
        'me',
        'peer',
        'received',
        mine: false,
        envelopeId: 'env-1',
      ),
    ]);

    final messages = store.getSecureConversation('me', 'peer');
    expect(
      messages.map((message) => message.text),
      containsAllInOrder(['first', 'second', 'received']),
    );

    final reloaded = ChatStore(await SharedPreferences.getInstance());
    expect(
      reloaded
          .getSecureConversation('me', 'peer')
          .map((message) => message.text),
      containsAllInOrder(['first', 'second', 'received']),
    );
  });

  test(
    'retrying the same client id does not duplicate a sent message',
    () async {
      final store = await secureStore();
      await store.addSecureMessage(
        'me',
        'peer',
        'hello',
        mine: true,
        clientId: 'retry-1',
      );
      await store.addSecureMessage(
        'me',
        'peer',
        'hello',
        mine: true,
        clientId: 'retry-1',
      );

      expect(store.getSecureConversation('me', 'peer'), hasLength(1));
    },
  );
}
