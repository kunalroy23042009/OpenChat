import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_chat/src/backup/chat_backup.dart';
import 'package:open_chat/src/chat_store.dart';
import 'package:open_chat/src/security/secure_history_database.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test(
    'SQLite-only chats survive encrypted backup and fresh database restore',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'openchat-recovery-',
      );
      addTearDown(() => directory.delete(recursive: true));
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final source = SecureHistoryDatabase(
        databasePath: path.join(directory.path, 'source.db'),
        testKey: List<int>.filled(32, 5),
      );
      await source.initialize(preferences);
      addTearDown(source.close);
      final store = ChatStore(preferences, secureHistory: source);
      await store.addSecureMessage(
        'account',
        'peer',
        'recover me',
        mine: true,
        clientId: 'one',
      );
      await store.addSecureMessage(
        'other-account',
        'peer',
        'different account',
        mine: true,
        clientId: 'two',
      );
      expect(
        preferences.getKeys().where(
          (key) => key.startsWith('openchat.secure.'),
        ),
        isEmpty,
      );
      final bytes = await ChatBackup.sealWithPassword(
        'account',
        store,
        'recovery-password',
      );
      final payload = await ChatBackup.openWithPassword(
        bytes,
        'recovery-password',
      );
      final peers = Map<String, dynamic>.from(payload['peers'] as Map);
      expect(peers.keys, ['peer']);
      expect((peers['peer'] as Map)['messages'], hasLength(1));

      final targetPath = path.join(directory.path, 'target.db');
      final target = SecureHistoryDatabase(
        databasePath: targetPath,
        testKey: List<int>.filled(32, 8),
      );
      await target.initialize(preferences);
      final restored = ChatStore(preferences, secureHistory: target);
      await restored.importSecureBackup('account', peers);
      await restored.importSecureBackup('account', peers);
      await target.close();
      final reopened = SecureHistoryDatabase(
        databasePath: targetPath,
        testKey: List<int>.filled(32, 8),
      );
      await reopened.initialize(preferences);
      addTearDown(reopened.close);
      final recovered = ChatStore(preferences, secureHistory: reopened);
      expect(
        recovered.getSecureConversation('account', 'peer').single.text,
        'recover me',
      );
      expect(recovered.getSecureConversation('other-account', 'peer'), isEmpty);
    },
  );

  test('migrates old history, encrypts it, and reopens durably', () async {
    final directory = await Directory.systemTemp.createTemp(
      'openchat-history-',
    );
    addTearDown(() => directory.delete(recursive: true));
    const storageKey = 'openchat.secure.v1.account-peer';
    const secretText = 'private conversation text';
    SharedPreferences.setMockInitialValues({
      storageKey: jsonEncode({
        'messages': [
          {
            'text': secretText,
            'mine': true,
            'at': DateTime.utc(2026).toIso8601String(),
          },
        ],
      }),
    });
    final preferences = await SharedPreferences.getInstance();
    final dbPath = path.join(directory.path, 'history.db');
    final key = List<int>.generate(32, (i) => i);

    final first = SecureHistoryDatabase(databasePath: dbPath, testKey: key);
    await first.initialize(preferences);
    expect(preferences.getString(storageKey), isNull);
    expect(first.read(storageKey), contains(secretText));
    await first.close();

    final rawDb = await databaseFactory.openDatabase(dbPath);
    final rows = await rawDb.query('secure_histories');
    final rawBytes = rows.single['payload']! as List<int>;
    expect(
      utf8.decode(rawBytes, allowMalformed: true),
      isNot(contains(secretText)),
    );
    await rawDb.close();

    final second = SecureHistoryDatabase(databasePath: dbPath, testKey: key);
    await second.initialize(preferences);
    expect(second.read(storageKey), contains(secretText));
    await second.close();
  });

  test(
    'refuses corrupted ciphertext without replacing the stored row',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'openchat-history-',
      );
      addTearDown(() => directory.delete(recursive: true));
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final dbPath = path.join(directory.path, 'history.db');
      final key = List<int>.filled(32, 7);
      const storageKey = 'openchat.secure.v1.account-peer';
      final first = SecureHistoryDatabase(databasePath: dbPath, testKey: key);
      await first.initialize(preferences);
      await first.write(storageKey, '{"messages":[]}');
      await first.close();

      final rawDb = await databaseFactory.openDatabase(dbPath);
      final payload =
          (await rawDb.query('secure_histories')).single['payload']!
              as List<int>;
      final corrupted = Uint8List.fromList(payload)
        ..[payload.length - 1] ^= 0xFF;
      await rawDb.update('secure_histories', {'payload': corrupted});
      await rawDb.close();

      final reopened = SecureHistoryDatabase(
        databasePath: dbPath,
        testKey: key,
      );
      await expectLater(
        reopened.initialize(preferences),
        throwsA(
          isA<StateError>().having(
            (error) => error.message.toString(),
            'message',
            contains('failed authentication'),
          ),
        ),
      );
      await reopened.close();
    },
  );

  test(
    'ChatStore commits direct history to encrypted durable storage',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'openchat-history-',
      );
      addTearDown(() => directory.delete(recursive: true));
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final dbPath = path.join(directory.path, 'history.db');
      final key = List<int>.filled(32, 11);
      final history = SecureHistoryDatabase(databasePath: dbPath, testKey: key);
      await history.initialize(preferences);
      final store = ChatStore(preferences, secureHistory: history);
      await store.addSecureMessage(
        'account',
        'peer',
        'private local history',
        mine: true,
        clientId: 'out-1',
      );
      expect(
        store.getSecureConversation('account', 'peer').single.text,
        'private local history',
      );
      expect(preferences.getString('openchat.secure.v1.account-peer'), isNull);
      await history.close();

      final reopenedHistory = SecureHistoryDatabase(
        databasePath: dbPath,
        testKey: key,
      );
      await reopenedHistory.initialize(preferences);
      final reopenedStore = ChatStore(
        preferences,
        secureHistory: reopenedHistory,
      );
      expect(
        reopenedStore.getSecureConversation('account', 'peer').single.text,
        'private local history',
      );
      await reopenedHistory.close();
    },
  );

  test('group backup restore merges into an encrypted local archive', () async {
    final directory = await Directory.systemTemp.createTemp(
      'openchat-group-archive-',
    );
    addTearDown(() => directory.delete(recursive: true));
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final history = SecureHistoryDatabase(
      databasePath: path.join(directory.path, 'history.db'),
      testKey: List<int>.filled(32, 3),
    );
    await history.initialize(preferences);
    final store = ChatStore(preferences, secureHistory: history);
    await store.importGroupBackup('account', {
      'group-1': {
        'conversation': {'id': 'group-1', 'title': 'Team'},
        'messages': [
          {
            'id': 'message-1',
            'created_at': '2026-01-02T00:00:00.000Z',
            'content': 'archived message',
          },
        ],
      },
    });
    final archive =
        jsonDecode(store.groupArchive('account', 'group-1')!) as Map;
    expect((archive['messages'] as List).single['content'], 'archived message');
    expect(
      preferences.getString('openchat.groupArchive.v1.account.group-1'),
      isNull,
    );
    await history.close();
  });
}
