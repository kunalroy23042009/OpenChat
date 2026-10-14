import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

/// Durable local store for direct-message history.
///
/// Every history document is AES-256-GCM encrypted before it reaches SQLite.
/// The database uses committed transactions; its random data key is held in
/// platform secure storage and is never written into the database/preferences.
class SecureHistoryDatabase {
  SecureHistoryDatabase({
    this.secureStorage = const FlutterSecureStorage(),
    this.databasePath,
    this.testKey,
  });

  static const _keyName = 'openchat.secureHistoryKey.v1';
  static const _table = 'secure_histories';
  static const _prefix = 'openchat.secure.v1.';
  static final _aead = AesGcm.with256bits();

  final FlutterSecureStorage secureStorage;
  final String? databasePath;
  final List<int>? testKey;
  final Map<String, String> _cache = {};
  Database? _db;
  SecretKey? _key;

  bool get isInitialized => _db != null && _key != null;

  Future<void> initialize(SharedPreferences preferences) async {
    if (isInitialized) return;
    final keyBytes = await _loadOrCreateKey();
    _key = SecretKey(keyBytes);
    final dbPath =
        databasePath ??
        path.join(await getDatabasesPath(), 'openchat_history.db');
    _db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE $_table (
            storage_key TEXT PRIMARY KEY NOT NULL,
            payload BLOB NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX secure_histories_updated ON $_table(updated_at)',
        );
      },
    );

    final rows = await _db!.query(_table);
    for (final row in rows) {
      final storageKey = row['storage_key']! as String;
      _cache[storageKey] = await _open(
        storageKey,
        Uint8List.fromList(row['payload']! as List<int>),
      );
    }

    // One-time, crash-safe migration from the old plaintext preferences.
    // Retain the source value until its encrypted SQLite row is committed.
    for (final storageKey in preferences.getKeys().where(
      (key) => key.startsWith(_prefix),
    )) {
      final legacy = preferences.getString(storageKey);
      if (legacy == null || _cache.containsKey(storageKey)) continue;
      jsonDecode(legacy); // Validate before committing/removing the source.
      await write(storageKey, legacy);
      await preferences.remove(storageKey);
    }
  }

  Future<List<int>> _loadOrCreateKey() async {
    final injectedKey = testKey;
    if (injectedKey != null) {
      if (injectedKey.length != 32) {
        throw ArgumentError('Test key must be 32 bytes');
      }
      return injectedKey;
    }
    final encoded = await secureStorage.read(key: _keyName);
    if (encoded != null) {
      final key = base64Decode(encoded);
      if (key.length != 32) {
        throw StateError(
          'Secure chat storage key is invalid; history was not changed.',
        );
      }
      return key;
    }
    final key = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    await secureStorage.write(key: _keyName, value: base64Encode(key));
    return key;
  }

  String? read(String storageKey) {
    if (!isInitialized) {
      throw StateError('Secure history database is not initialized.');
    }
    return _cache[storageKey];
  }

  Map<String, String> readEntries(String prefix) => {
    for (final entry in _cache.entries)
      if (entry.key.startsWith(prefix)) entry.key: entry.value,
  };

  Future<void> write(String storageKey, String json) async {
    final db = _db;
    if (db == null || _key == null) {
      throw StateError('Secure history database is not initialized.');
    }
    final payload = await _seal(storageKey, json);
    await db.transaction((txn) async {
      await txn.insert(_table, {
        'storage_key': storageKey,
        'payload': payload,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    _cache[storageKey] = json;
  }

  Future<Uint8List> _seal(String storageKey, String clearText) async {
    final nonce = _aead.newNonce();
    final box = await _aead.encrypt(
      utf8.encode(clearText),
      secretKey: _key!,
      nonce: nonce,
      aad: utf8.encode(storageKey),
    );
    return Uint8List.fromList([...nonce, ...box.mac.bytes, ...box.cipherText]);
  }

  Future<String> _open(String storageKey, Uint8List bytes) async {
    if (bytes.length < 28) {
      throw StateError('Encrypted chat history is damaged.');
    }
    final nonce = bytes.sublist(0, 12);
    final mac = bytes.sublist(12, 28);
    final cipherText = bytes.sublist(28);
    try {
      final clear = await _aead.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
        secretKey: _key!,
        aad: utf8.encode(storageKey),
      );
      return utf8.decode(clear);
    } catch (_) {
      throw StateError(
        'Encrypted chat history failed authentication; original data was preserved.',
      );
    }
  }

  Future<void> close() async {
    final db = _db;
    _db = null;
    _key = null;
    _cache.clear();
    await db?.close();
  }
}
