import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:open_chat/src/backup/chat_backup.dart';
import 'package:open_chat/src/chat_store.dart';

Future<ChatStore> _store() async {
  SharedPreferences.setMockInitialValues({});
  return ChatStore(await SharedPreferences.getInstance());
}

void main() {
  test('backup seals and opens with the right password', () async {
    final store = await _store();
    await store.addSecureMessage(
      'a',
      'p1',
      'hello',
      mine: true,
      clientId: 'c1',
    );
    await store.addSecureMessage(
      'a',
      'p1',
      'hi back',
      mine: false,
      peerClientId: 'c2',
    );
    await store.toggleSecureStar('a', 'p1', 'out:c1');
    final bytes = await ChatBackup.sealWithPassword(
      'a',
      store,
      'correct-horse-9',
      groups: {
        'g1': {
          'conversation': {'id': 'g1', 'title': 'Team'},
          'messages': [
            {'id': 'm1', 'content': 'group history'},
          ],
        },
      },
    );
    expect(bytes.length, greaterThan(64));
    final payload = await ChatBackup.openWithPassword(bytes, 'correct-horse-9');
    expect(payload['v'], 1);
    expect((payload['peers'] as Map).length, 1);
    expect(((payload['groups'] as Map)['g1'] as Map)['messages'], hasLength(1));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('wrong password and tampered bytes fail friendly', () async {
    final store = await _store();
    await store.addSecureMessage(
      'a',
      'p1',
      'hello',
      mine: true,
      clientId: 'c1',
    );
    final bytes = await ChatBackup.sealWithPassword(
      'a',
      store,
      'correct-horse-9',
    );
    expect(
      () => ChatBackup.openWithPassword(bytes, 'wrong-password-1'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message.toString(),
          'message',
          contains('Wrong backup password'),
        ),
      ),
    );
    final tampered = Uint8List.fromList(bytes.toList())
      ..[bytes.length - 1] ^= 0xFF;
    expect(
      () => ChatBackup.openWithPassword(tampered, 'correct-horse-9'),
      throwsA(isA<StateError>()),
    );
    expect(
      () => ChatBackup.sealWithPassword('a', store, 'short'),
      throwsA(isA<StateError>()),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('media backup objects are authenticated and path-bound', () async {
    final key = await ChatBackup.deriveKey(
      'correct-horse-9',
      Uint8List.fromList(List<int>.filled(16, 9)),
    );
    final source = Uint8List.fromList([0, 1, 2, 3, 255]);
    final sealed = await ChatBackup.sealMediaBytes(
      key,
      'owner/peer/photo.enc',
      source,
    );
    expect(
      await ChatBackup.openMediaBytes(key, 'owner/peer/photo.enc', sealed),
      source,
    );
    await expectLater(
      ChatBackup.openMediaBytes(key, 'owner/peer/other.enc', sealed),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
  });

  test('export merges into a fresh store without duplicates', () async {
    final source = await _store();
    await source.addSecureMessage(
      'a',
      'p1',
      'hello',
      mine: true,
      clientId: 'c1',
    );
    await source.addSecureMessage(
      'a',
      'p2',
      'other chat',
      mine: false,
      peerClientId: 'c9',
    );
    final exported = source.exportSecureBackup('a');
    expect(exported.length, 2);

    final target = await _store();
    final first = await target.importSecureBackup(
      'a',
      Map<String, dynamic>.from(exported),
    );
    expect(first, 2);
    expect(target.getSecureConversation('a', 'p1').length, 1);
    // Local-only row survives the merge.
    await target.addSecureMessage(
      'a',
      'p1',
      'newer',
      mine: true,
      clientId: 'c2',
    );
    final second = await target.importSecureBackup(
      'a',
      Map<String, dynamic>.from(exported),
    );
    expect(second, 2);
    final rows = target.getSecureConversation('a', 'p1');
    expect(rows.length, 2);
    expect(rows.last.text, 'newer');
  });
}
