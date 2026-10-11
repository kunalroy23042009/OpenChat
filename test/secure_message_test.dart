import 'package:flutter_test/flutter_test.dart';
import 'package:open_chat/src/chat_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<ChatStore> secureStore() async {
  SharedPreferences.setMockInitialValues({});
  return ChatStore(await SharedPreferences.getInstance());
}

void main() {
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
