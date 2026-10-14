import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../chat_store.dart';
import '../chat/conversation_repository.dart';
import '../media/media_message.dart';

/// Encrypted cloud backup, WhatsApp-style (#366-373).
///
/// One AES-256-GCM blob per account at `chat-backups/<uid>/backup.enc`,
/// sealed on-device with a password-derived Argon2id key; the server only
/// ever sees ciphertext. Message rows carry their sealed media keys and
/// media bytes persist in `chat-media`, so photos/videos re-download on
/// demand after a restore. Blob layout:
/// `OCBK1` + salt(16) + nonce(12) + cipher+tag.
///
/// The derived key (+salt) is remembered in secure storage after the first
/// manual backup so scheduled backups run silently; a restore on any
/// device needs only the password.
class ChatBackup {
  static const bucket = 'chat-backups';
  static const _mediaBucket = 'chat-media';
  static String path(String uid) => '$uid/backup.enc';
  static String _versionedPath(String uid, String snapshotId) =>
      '$uid/backup_$snapshotId.enc';
  static const _retainedGenerations = 3;
  static const _chunkBytes = 8 * 1024 * 1024;
  static const _magic = 'OCBK1';
  static final _aes = AesGcm.with256bits();
  static final _kdf = Argon2id(
    parallelism: 1,
    memory: 19456,
    iterations: 2,
    hashLength: 32,
  );
  static const _secureStorage = FlutterSecureStorage();

  static String _freqKey(String uid) => 'openchat.backup.freq.v1.$uid';
  static String _lastKey(String uid) => 'openchat.backup.last.v1.$uid';
  static String _keyKey(String uid) => 'openchat.backupKey.v1.$uid';
  static String _mediaKeyKey(String uid) => 'openchat.backupMediaKey.v1.$uid';
  static String _mediaMapKey(String uid) => 'openchat.backupMediaMap.v1.$uid';

  static const frequencies = ['never', 'daily', 'weekly', 'monthly'];

  static void checkPassword(String password) {
    if (password.length < 8) {
      throw StateError('Backup password needs at least 8 characters.');
    }
  }

  static Future<SecretKey> deriveKey(String password, Uint8List salt) async {
    checkPassword(password);
    return _kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
  }

  static Future<Uint8List> _mediaKey(String uid) async {
    final saved = await _secureStorage.read(key: _mediaKeyKey(uid));
    if (saved != null) {
      final decoded = base64Decode(saved);
      if (decoded.length == 32) return Uint8List.fromList(decoded);
    }
    final key = Uint8List.fromList(
      List<int>.generate(32, (_) => Random.secure().nextInt(256)),
    );
    await _secureStorage.write(
      key: _mediaKeyKey(uid),
      value: base64Encode(key),
    );
    return key;
  }

  static Future<Uint8List?> _storedMediaKey(String uid) async {
    try {
      final saved = await _secureStorage.read(key: _mediaKeyKey(uid));
      if (saved == null) return null;
      final decoded = base64Decode(saved);
      return decoded.length == 32 ? Uint8List.fromList(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  static Uint8List _randomSalt() => Uint8List.fromList(
    List<int>.generate(16, (_) => Random.secure().nextInt(256)),
  );

  static Future<Uint8List> sealMediaBytes(
    SecretKey key,
    String sourcePath,
    Uint8List clear,
  ) async {
    final nonce = _aes.newNonce();
    final box = await _aes.encrypt(
      clear,
      secretKey: key,
      nonce: nonce,
      aad: utf8.encode(sourcePath),
    );
    return Uint8List.fromList([
      ...utf8.encode('OCBM1'),
      ...nonce,
      ...box.mac.bytes,
      ...box.cipherText,
    ]);
  }

  static Future<Uint8List> openMediaBytes(
    SecretKey key,
    String sourcePath,
    Uint8List sealed,
  ) async {
    if (sealed.length < 33 || utf8.decode(sealed.sublist(0, 5)) != 'OCBM1') {
      throw StateError('Archived media object is damaged.');
    }
    return Uint8List.fromList(
      await _aes.decrypt(
        SecretBox(
          sealed.sublist(33),
          nonce: sealed.sublist(5, 17),
          mac: Mac(sealed.sublist(17, 33)),
        ),
        secretKey: key,
        aad: utf8.encode(sourcePath),
      ),
    );
  }

  static String _newSnapshotId() =>
      DateTime.now().toUtc().microsecondsSinceEpoch.toString();

  static Future<List<dynamic>> _listBucketFiles(
    SupabaseClient client,
    String uid,
  ) async {
    final files = <dynamic>[];
    String? cursor;
    do {
      final page = await client.storage
          .from(bucket)
          .listPaginated(
            options: PaginatedSearchOptions(
              prefix: uid,
              limit: 1000,
              cursor: cursor,
            ),
          );
      files.addAll(page.objects);
      cursor = page.hasNext ? page.nextCursor : null;
    } while (cursor != null);
    return files;
  }

  static Future<List<String>> _uploadParts(
    SupabaseClient client,
    String uid,
    String prefix,
    Uint8List bytes, {
    bool upsert = false,
  }) async {
    final paths = <String>[];
    var offset = 0;
    var index = 0;
    while (offset < bytes.length) {
      final end = min(offset + _chunkBytes, bytes.length);
      final objectPath = '$uid/${prefix}_part_$index.blob';
      await client.storage
          .from(bucket)
          .uploadBinary(
            objectPath,
            Uint8List.sublistView(bytes, offset, end),
            fileOptions: FileOptions(
              contentType: 'application/octet-stream',
              upsert: upsert,
            ),
          );
      paths.add(objectPath);
      offset = end;
      index++;
    }
    return paths;
  }

  static Future<Uint8List> _downloadParts(
    SupabaseClient client,
    String uid,
    String prefix,
    Uint8List descriptor,
  ) async {
    if (descriptor.length < 6 ||
        utf8.decode(descriptor.sublist(0, 6)) != 'OCBC1:') {
      return descriptor; // Legacy single-object backup.
    }
    final manifest = jsonDecode(utf8.decode(descriptor.sublist(6))) as Map;
    final totalBytes = manifest['bytes'] as int;
    final digest = manifest['sha256'] as String;
    final parts = (manifest['parts'] as List).cast<String>();
    if (totalBytes <= 0 ||
        totalBytes > 2 * 1024 * 1024 * 1024 ||
        parts.isEmpty) {
      throw StateError('Invalid backup chunk manifest.');
    }
    final joined = BytesBuilder(copy: false);
    for (var i = 0; i < parts.length; i++) {
      final expected = '$uid/${prefix}_part_$i.blob';
      if (parts[i] != expected) throw StateError('Invalid backup chunk path.');
      joined.add(await client.storage.from(bucket).download(expected));
    }
    final bytes = joined.takeBytes();
    if (bytes.length != totalBytes ||
        crypto.sha256.convert(bytes).toString() != digest) {
      throw StateError('Backup chunks are incomplete or corrupted.');
    }
    return bytes;
  }

  static Set<String> _referencedMedia(
    ChatStore store,
    String uid,
    Map<String, dynamic> groups,
  ) {
    final paths = <String>{};
    final peers = store.exportSecureBackup(uid);
    for (final peer in peers.values) {
      for (final raw in (peer as Map)['messages'] as List) {
        final body = parseMessageBody((raw as Map)['text'] as String);
        if (body.path != null && body.path!.isNotEmpty) paths.add(body.path!);
        if (body.thumbPath != null && body.thumbPath!.isNotEmpty) {
          paths.add(body.thumbPath!);
        }
      }
    }
    for (final archive in groups.values) {
      for (final raw in (archive as Map)['messages'] as List) {
        final message = raw as Map;
        final path = message['media_url'] as String?;
        if (path != null && path.isNotEmpty) paths.add(path);
        final metadata = message['metadata'] as Map?;
        for (final key in const ['thumb_path', 'path']) {
          final value = metadata?[key] as String?;
          if (value != null && value.isNotEmpty) paths.add(value);
        }
      }
    }
    return paths;
  }

  static Future<({Map<String, dynamic> manifest, int bytes})> _copyBackupMedia({
    required SupabaseClient client,
    required ChatStore store,
    required String uid,
    required SecretKey key,
    required String snapshotId,
    required Map<String, dynamic> groups,
  }) async {
    final sources = _referencedMedia(store, uid, groups);
    final objects = <String>{};
    for (final source in sources) {
      if (source.endsWith('/manifest.enc')) {
        final folder = source.substring(0, source.lastIndexOf('/'));
        final listing = await client.storage
            .from(_mediaBucket)
            .list(path: folder);
        for (final file in listing) {
          if (file.name.isNotEmpty) objects.add('$folder/${file.name}');
        }
      } else {
        objects.add(source);
      }
    }

    final manifest = <String, dynamic>{};
    var totalBytes = 0;
    var index = 0;
    for (final source in objects) {
      final clear = await client.storage.from(_mediaBucket).download(source);
      final sealed = await sealMediaBytes(key, source, clear);
      final parts = await _uploadParts(
        client,
        uid,
        'media_${snapshotId}_$index',
        sealed,
        upsert: false,
      );
      manifest[source] = parts;
      totalBytes += sealed.length;
      index++;
    }
    return (manifest: manifest, bytes: totalBytes);
  }

  static Future<Uint8List> _seal(
    String accountId,
    ChatStore store,
    SecretKey key,
    Uint8List salt, {
    Map<String, dynamic> groups = const {},
    Map<String, dynamic> media = const {},
    Uint8List? backupMediaKey,
  }) async {
    final payload = utf8.encode(
      jsonEncode({
        'v': 1,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'account': accountId,
        'peers': store.exportSecureBackup(accountId),
        'groups': groups,
        'media': media,
        'mediaKey': base64Encode(
          backupMediaKey ?? _randomSalt() + _randomSalt(),
        ),
      }),
    );
    final compressed = payload;
    final nonce = _aes.newNonce();
    final box = await _aes.encrypt(compressed, secretKey: key, nonce: nonce);
    return Uint8List.fromList([
      ...utf8.encode(_magic),
      ...salt,
      ...nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
  }

  /// Seals with a fresh salt (manual backups, tests).
  static Future<Uint8List> sealWithPassword(
    String accountId,
    ChatStore store,
    String password, {
    Map<String, dynamic> groups = const {},
    Map<String, dynamic> media = const {},
    Uint8List? backupMediaKey,
  }) async {
    final salt = _randomSalt();
    return _seal(
      accountId,
      store,
      await deriveKey(password, salt),
      salt,
      groups: groups,
      media: media,
      backupMediaKey: backupMediaKey,
    );
  }

  /// Opens a blob sealed by [_seal]. Throws a friendly StateError on wrong
  /// password or damaged data (GCM authentication failure covers both).
  static Future<Map<String, dynamic>> openWithKey(
    Uint8List bytes,
    SecretKey key,
  ) async {
    try {
      if (bytes.length < 5 + 16 + 12 + 17) throw StateError('truncated');
      if (utf8.decode(bytes.sublist(0, 5)) != _magic) {
        throw StateError('bad header');
      }
      final nonce = bytes.sublist(5 + 16, 5 + 16 + 12);
      final cipher = bytes.sublist(5 + 16 + 12);
      final box = SecretBox(
        cipher.sublist(0, cipher.length - 16),
        nonce: nonce,
        mac: Mac(cipher.sublist(cipher.length - 16)),
      );
      final clear = await _aes.decrypt(box, secretKey: key);
      final payload = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
      if (payload['v'] != 1 || payload['peers'] is! Map) {
        throw StateError('unsupported');
      }
      return payload;
    } catch (_) {
      throw StateError('Wrong backup password or damaged backup file.');
    }
  }

  /// Opens with a password (re-derives via the header salt).
  static Future<Map<String, dynamic>> openWithPassword(
    Uint8List bytes,
    String password,
  ) async {
    checkPassword(password);
    if (bytes.length < 5 + 16 + 12 + 17) {
      throw StateError('Wrong backup password or damaged backup file.');
    }
    final salt = bytes.sublist(5, 5 + 16);
    return openWithKey(bytes, await deriveKey(password, salt));
  }

  static Future<void> _rememberKey(
    String uid,
    SecretKey key,
    Uint8List salt,
  ) async {
    await _secureStorage.write(
      key: _keyKey(uid),
      value: jsonEncode({
        'k': base64Encode(await key.extractBytes()),
        's': base64Encode(salt),
      }),
    );
  }

  static Future<({SecretKey key, Uint8List salt})?> _storedKey(
    String uid,
  ) async {
    try {
      final raw = await _secureStorage.read(key: _keyKey(uid));
      if (raw == null || raw.isEmpty) return null;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      return (
        key: SecretKey(base64Decode(data['k'] as String)),
        salt: Uint8List.fromList(base64Decode(data['s'] as String).toList()),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> forgetKey(String uid) async {
    try {
      await _secureStorage.delete(key: _keyKey(uid));
    } catch (_) {}
  }

  static Future<void> forgetMediaKey(String uid) async {
    try {
      await _secureStorage.delete(key: _mediaKeyKey(uid));
    } catch (_) {}
  }

  static Future<void> uploadBackup(
    SupabaseClient client,
    String uid,
    Uint8List bytes,
    String snapshotId,
  ) async {
    final snapshotPath = _versionedPath(uid, snapshotId);
    final parts = await _uploadParts(client, uid, 'backup_$snapshotId', bytes);
    final descriptor = Uint8List.fromList(
      utf8.encode(
        'OCBC1:${jsonEncode({'bytes': bytes.length, 'sha256': crypto.sha256.convert(bytes).toString(), 'parts': parts})}',
      ),
    );
    await client.storage
        .from(bucket)
        .uploadBinary(
          snapshotPath,
          descriptor,
          fileOptions: const FileOptions(
            contentType: 'application/octet-stream',
            upsert: true,
          ),
        );
    final paths = await _listBackupPaths(client, uid);
    if (paths.length > _retainedGenerations) {
      await client.storage
          .from(bucket)
          .remove(paths.skip(_retainedGenerations).toList());
    }
    // Only prune generations whose committed manifests were retired above.
    // Unlisted chunks may belong to a concurrent, still-uploading snapshot.
    final retiredIds = paths.skip(_retainedGenerations).map((value) {
      final name = value.substring(value.lastIndexOf('/') + 1);
      if (name == 'backup.enc') return '';
      return name.substring('backup_'.length, name.length - '.enc'.length);
    }).toSet();
    final files = await _listBucketFiles(client, uid);
    final orphanedMedia = <String>[];
    final mediaName = RegExp(r'^media_(\d+)_\d+_part_\d+\.blob$');
    for (final file in files) {
      final match = mediaName.firstMatch(file.name);
      if (match != null && retiredIds.contains(match.group(1))) {
        if (file.key != null) orphanedMedia.add(file.key!);
      }
      final chunkName = RegExp(r'^backup_(\d+)_part_\d+\.blob$')
          .firstMatch(file.name);
      if (chunkName != null && retiredIds.contains(chunkName.group(1))) {
        if (file.key != null) orphanedMedia.add(file.key!);
      }
    }
    if (orphanedMedia.isNotEmpty) {
      await client.storage.from(bucket).remove(orphanedMedia);
    }
  }

  static Future<Uint8List?> downloadBackup(
    SupabaseClient client,
    String uid,
  ) async {
    final backups = await downloadBackups(client, uid);
    return backups.isEmpty ? null : backups.first;
  }

  /// Resolves an original chat-media object from the encrypted backup copy.
  /// Called by media/document readers only after the original object is absent.
  static Future<Uint8List?> restoreMediaBytes(
    SupabaseClient client,
    String sourcePath,
  ) async {
    final uid = client.auth.currentUser?.id;
    if (uid == null) return null;
    final prefs = await SharedPreferences.getInstance();
    try {
      final rawMap = prefs.getString(_mediaMapKey(uid));
      if (rawMap == null) return null;
      final manifest = Map<String, dynamic>.from(jsonDecode(rawMap) as Map);
      final mediaValue = manifest[sourcePath];
      if (mediaValue == null) return null;
      final paths = mediaValue is String
          ? [mediaValue]
          : (mediaValue as List).cast<String>();
      final mediaKey = await _storedMediaKey(uid);
      if (mediaKey == null) return null;
      final joined = BytesBuilder(copy: false);
      for (final objectPath in paths) {
        if (!objectPath.startsWith('$uid/media_') ||
            !objectPath.endsWith('.blob')) {
          return null;
        }
        joined.add(await client.storage.from(bucket).download(objectPath));
      }
      final bytes = joined.takeBytes();
      return await openMediaBytes(SecretKey(mediaKey), sourcePath, bytes);
    } catch (_) {
      return null;
    }
  }

  /// Retained encrypted generations ordered newest-first for recovery.
  static Future<List<Uint8List>> downloadBackups(
    SupabaseClient client,
    String uid,
  ) async {
    final paths = await _listBackupPaths(client, uid);
    final result = <Uint8List>[];
    for (final backupPath in paths) {
      try {
        final descriptor = await client.storage
            .from(bucket)
            .download(backupPath);
        if (backupPath.endsWith('/backup.enc')) {
          result.add(descriptor);
        } else {
          final name = backupPath.substring(backupPath.lastIndexOf('/') + 1);
          final snapshotId = name.substring('backup_'.length, name.length - 4);
          result.add(
            await _downloadParts(client, uid, 'backup_$snapshotId', descriptor),
          );
        }
      } catch (_) {
        // Keep trying older generations if a single object is unreadable.
      }
    }
    return result;
  }

  static Future<List<String>> _listBackupPaths(
    SupabaseClient client,
    String uid,
  ) async {
    final files = await _listBucketFiles(client, uid);
    final backups = files
        .where(
          (file) =>
              file.name == 'backup.enc' ||
              RegExp(r'^backup_\d+\.enc$').hasMatch(file.name),
        )
        .toList();
    backups.sort((a, b) {
      final atA = DateTime.tryParse(a.updatedAt ?? '') ?? DateTime(1970);
      final atB = DateTime.tryParse(b.updatedAt ?? '') ?? DateTime(1970);
      final time = atB.compareTo(atA);
      return time != 0 ? time : b.name.compareTo(a.name);
    });
    return backups
        .map((file) => file.key ?? '$uid/${file.name}')
        .cast<String>()
        .toList();
  }

  static Future<void> deleteBackup(SupabaseClient client, String uid) async {
    final files = await _listBucketFiles(client, uid);
    final objects = files
        .where(
          (file) =>
              file.name == 'backup.enc' ||
              file.name.startsWith('backup_') ||
              (file.name.startsWith('media_') && file.name.endsWith('.blob')),
        )
        .map((file) => file.key ?? '$uid/${file.name}')
        .toList();
    if (objects.isNotEmpty) {
      await client.storage.from(bucket).remove(objects.cast<String>());
    }
  }

  static Future<void> forgetLocalMediaMap(
    SharedPreferences prefs,
    String uid,
  ) async {
    await prefs.remove(_mediaMapKey(uid));
  }

  /// Last-backup metadata for the status card (null when never backed up).
  static Future<({DateTime updatedAt, int bytes})?> backupInfo(
    SupabaseClient client,
    String uid,
  ) async {
    try {
      final rows = await _listBucketFiles(client, uid);
      final backups =
          rows
              .where(
                (file) =>
                    file.name == 'backup.enc' ||
                    RegExp(r'^backup_\d+\.enc$').hasMatch(file.name),
              )
              .toList()
            ..sort((a, b) {
              final atA =
                  DateTime.tryParse(a.updatedAt ?? '') ?? DateTime(1970);
              final atB =
                  DateTime.tryParse(b.updatedAt ?? '') ?? DateTime(1970);
              return atB.compareTo(atA);
            });
      if (backups.isNotEmpty) {
        final file = backups.first;
        final updated = DateTime.tryParse(file.updatedAt ?? '');
        var size = (file.metadata?['size'] as num?)?.toInt() ?? 0;
        if (file.name != 'backup.enc') {
          final snapshotId = file.name.substring(
            'backup_'.length,
            file.name.length - 4,
          );
          for (final media in rows.where(
            (item) => item.name.startsWith('backup_${snapshotId}_part_'),
          )) {
            size += (media.metadata?['size'] as num?)?.toInt() ?? 0;
          }
        }
        if (file.name != 'backup.enc') {
          final snapshotId = file.name.substring(
            'backup_'.length,
            file.name.length - 4,
          );
          for (final media in rows.where(
            (item) => item.name.startsWith('media_${snapshotId}_'),
          )) {
            size += (media.metadata?['size'] as num?)?.toInt() ?? 0;
          }
        }
        if (updated != null) return (updatedAt: updated, bytes: size);
      }
    } catch (_) {}
    return null;
  }

  static String frequency(SharedPreferences prefs, String uid) {
    final value = prefs.getString(_freqKey(uid)) ?? 'weekly';
    return frequencies.contains(value) ? value : 'weekly';
  }

  static Future<void> setFrequency(
    SharedPreferences prefs,
    String uid,
    String value,
  ) async {
    if (!frequencies.contains(value)) return;
    await prefs.setString(_freqKey(uid), value);
  }

  static DateTime? lastBackup(SharedPreferences prefs, String uid) {
    final ms = prefs.getInt(_lastKey(uid));
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// Full backup with an explicit password. Remembers the derived key on
  /// this device so scheduled backups run silently afterwards.
  static Future<({int peers, int groups, int messages, int bytes})> backupNow({
    required SupabaseClient client,
    required ChatStore store,
    required String uid,
    required String password,
    required SharedPreferences prefs,
  }) async {
    final snapshotId = _newSnapshotId();
    final salt = _randomSalt();
    final key = await deriveKey(password, salt);
    final mediaKey = await _mediaKey(uid);
    final groups = await _exportGroupBackup(client, store);
    final mediaSnapshot = await _copyBackupMedia(
      client: client,
      store: store,
      uid: uid,
      key: SecretKey(mediaKey),
      snapshotId: snapshotId,
      groups: groups,
    );
    final bytes = await _seal(
      uid,
      store,
      key,
      salt,
      groups: groups,
      media: mediaSnapshot.manifest,
      backupMediaKey: mediaKey,
    );
    await uploadBackup(client, uid, bytes, snapshotId);
    await _rememberKey(uid, key, salt);
    await prefs.setString(
      _mediaMapKey(uid),
      jsonEncode(mediaSnapshot.manifest),
    );
    await prefs.setInt(_lastKey(uid), DateTime.now().millisecondsSinceEpoch);
    return _count(store, uid, bytes.length + mediaSnapshot.bytes, groups);
  }

  /// Silent scheduled backup using the remembered key. Returns null when
  /// nothing was due or no key is stored (needs one manual backup first).
  static Future<({int peers, int groups, int messages, int bytes})?>
  maybeAutoBackup({
    required SupabaseClient client,
    required ChatStore store,
    required String uid,
    required SharedPreferences prefs,
  }) async {
    try {
      final freq = frequency(prefs, uid);
      if (freq == 'never') return null;
      final last = lastBackup(prefs, uid);
      final due = switch (freq) {
        'daily' => const Duration(days: 1),
        'monthly' => const Duration(days: 30),
        _ => const Duration(days: 7),
      };
      if (last != null && DateTime.now().difference(last) < due) return null;
      final stored = await _storedKey(uid);
      if (stored == null) return null;
      final snapshotId = _newSnapshotId();
      final mediaKey = await _mediaKey(uid);
      final groups = await _exportGroupBackup(client, store);
      final mediaSnapshot = await _copyBackupMedia(
        client: client,
        store: store,
        uid: uid,
        key: SecretKey(mediaKey),
        snapshotId: snapshotId,
        groups: groups,
      );
      final bytes = await _seal(
        uid,
        store,
        stored.key,
        stored.salt,
        groups: groups,
        media: mediaSnapshot.manifest,
        backupMediaKey: mediaKey,
      );
      await uploadBackup(client, uid, bytes, snapshotId);
      await prefs.setString(
        _mediaMapKey(uid),
        jsonEncode(mediaSnapshot.manifest),
      );
      await prefs.setInt(_lastKey(uid), DateTime.now().millisecondsSinceEpoch);
      return _count(store, uid, bytes.length + mediaSnapshot.bytes, groups);
    } catch (_) {
      return null;
    }
  }

  static ({int peers, int groups, int messages, int bytes}) _count(
    ChatStore store,
    String uid,
    int bytes,
    Map<String, dynamic> groups,
  ) {
    final peers = store.exportSecureBackup(uid);
    var messages = 0;
    for (final entry in peers.entries) {
      messages += ((entry.value as Map)['messages'] as List).length;
    }
    for (final entry in groups.values) {
      messages += ((entry as Map)['messages'] as List).length;
    }
    return (
      peers: peers.length,
      groups: groups.length,
      messages: messages,
      bytes: bytes,
    );
  }

  /// Captures every member-visible group/channel message page. The resulting
  /// plaintext exists only inside the password-encrypted backup blob.
  static Future<Map<String, dynamic>> _exportGroupBackup(
    SupabaseClient client,
    ChatStore store,
  ) => ConversationRepository(
    client,
    secureHistory: store.secureHistory,
  ).exportGroupBackup();

  /// Restores the latest cloud backup into local state (merge, no drops).
  static Future<({int peers, int groups, int messages})> restoreLatest({
    required SupabaseClient client,
    required ChatStore store,
    required String uid,
    required String password,
  }) async {
    final backups = await downloadBackups(client, uid);
    if (backups.isEmpty) {
      throw StateError('No cloud backup found for this account.');
    }
    Map<String, dynamic>? payload;
    Uint8List? selectedBackup;
    for (final bytes in backups) {
      try {
        payload = await openWithPassword(bytes, password);
        selectedBackup = bytes;
        break;
      } on StateError {
        // Try the next retained snapshot before treating the backup as lost.
      }
    }
    if (payload == null) {
      throw StateError(
        'Wrong backup password or all retained backups are damaged.',
      );
    }
    if (payload['account'] != uid) {
      throw StateError('This backup belongs to a different account.');
    }
    final peers = Map<String, dynamic>.from(payload['peers'] as Map);
    final groups = Map<String, dynamic>.from(payload['groups'] as Map? ?? {});
    final media = Map<String, dynamic>.from(payload['media'] as Map? ?? {});
    if (media.isNotEmpty) {
      final mediaKey = base64Decode(payload['mediaKey'] as String? ?? '');
      if (mediaKey.length != 32) {
        throw StateError('Backup media key is missing or invalid.');
      }
      await _secureStorage.write(
        key: _mediaKeyKey(uid),
        value: base64Encode(mediaKey),
      );
    }
    final selected = selectedBackup!;
    final salt = Uint8List.fromList(selected.sublist(5, 21));
    await _rememberKey(uid, await deriveKey(password, salt), salt);
    await store.preferences.setString(_mediaMapKey(uid), jsonEncode(media));
    final importedPeers = await store.importSecureBackup(uid, peers);
    final importedGroups = await store.importGroupBackup(uid, groups);
    return (
      peers: peers.length,
      groups: groups.length,
      messages: importedPeers + importedGroups,
    );
  }
}
