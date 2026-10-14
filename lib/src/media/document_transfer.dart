import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../backup/chat_backup.dart';
import 'media_message.dart';
import 'media_seal.dart';

class TransferCancelled implements Exception {}

class TransferControl {
  bool cancelled = false;
  void check() {
    if (cancelled) throw TransferCancelled();
  }
}

/// A stored object reference for orphan detection (key + last write time).
class StoredObject {
  const StoredObject(this.key, this.updatedAt);
  final String key;
  final DateTime? updatedAt;
}

abstract class ChunkStorage {
  Future<void> put(String path, Uint8List bytes);
  Future<Uint8List> get(String path);
  Future<void> remove(List<String> paths);
  Future<List<StoredObject>> listDocObjects(String peerPrefix);
}

class SupabaseChunkStorage implements ChunkStorage {
  SupabaseChunkStorage(this.client);
  final SupabaseClient client;
  @override
  Future<void> put(String path, Uint8List bytes) async {
    await client.storage
        .from('chat-media')
        .uploadBinary(
          path,
          bytes,
          fileOptions: const FileOptions(
            contentType: 'application/octet-stream',
          ),
        );
  }

  @override
  Future<Uint8List> get(String path) async {
    try {
      return await client.storage.from('chat-media').download(path);
    } catch (_) {
      final restored = await ChatBackup.restoreMediaBytes(client, path);
      if (restored == null) rethrow;
      return restored;
    }
  }

  @override
  Future<void> remove(List<String> paths) async {
    for (var i = 0; i < paths.length; i += 100) {
      await client.storage
          .from('chat-media')
          .remove(paths.sublist(i, min(i + 100, paths.length)));
    }
  }

  @override
  Future<List<StoredObject>> listDocObjects(String peerPrefix) async {
    final out = <StoredObject>[];
    String? cursor;
    do {
      final page = await client.storage
          .from('chat-media')
          .listPaginated(
            options: PaginatedSearchOptions(
              prefix: peerPrefix,
              limit: 1000,
              cursor: cursor,
            ),
          );
      for (final o in page.objects) {
        if (o.key == null) continue;
        DateTime? updated;
        try {
          updated = o.updatedAt == null ? null : DateTime.parse(o.updatedAt!);
        } catch (_) {
          updated = null;
        }
        out.add(StoredObject(o.key!, updated));
      }
      cursor = page.hasNext ? page.nextCursor : null;
    } while (cursor != null);
    return out;
  }
}

/// Documents are independently sealed 4 MiB chunks plus an authenticated,
/// encrypted manifest. Neither transfer ever loads the entire file in RAM.
class DocumentTransfer {
  DocumentTransfer(this.storage, this.owner);
  final ChunkStorage storage;
  final String owner;
  // Pilot cap: 200 MB = 50x 4 MiB chunks max. Fits Supabase free-tier
  // (1 GB storage / 2 GB bandwidth) and stays usable on mobile.
  static const maxBytes = 200 * 1024 * 1024;
  static const chunkBytes = 4 * 1024 * 1024;
  static String safeName(String name) {
    final clean = name
        .split(RegExp(r'[/\\]'))
        .last
        .replaceAll(RegExp(r'[\x00-\x1f<>:"|?*]'), '_');
    if (clean.isEmpty || clean == '.' || clean == '..') return 'Document';
    return clean.length > 200 ? clean.substring(0, 200) : clean;
  }

  /// Groups object keys by upload prefix (`owner/peer/id`). A group is an
  /// orphan when it has no `manifest.enc` (the manifest is written last, so
  /// its absence means the upload never finished) and every timestamped file
  /// is older than [maxAge]. Entries without timestamps are never orphans.
  static List<String> findOrphanPrefixes(
    List<StoredObject> objects, {
    required DateTime now,
    Duration maxAge = const Duration(hours: 1),
  }) {
    final files = <String, List<StoredObject>>{};
    for (final o in objects) {
      final slash = o.key.lastIndexOf('/');
      if (slash <= 0) continue;
      files.putIfAbsent(o.key.substring(0, slash), () => []).add(o);
    }
    final orphans = <String>[];
    for (final entry in files.entries) {
      if (entry.value.any((o) => o.key.endsWith('/manifest.enc'))) continue;
      final times = [for (final o in entry.value) o.updatedAt];
      if (times.any((t) => t == null)) continue;
      if (times.every((t) => now.difference(t!) > maxAge)) {
        orphans.add(entry.key);
      }
    }
    return orphans;
  }

  /// Best-effort reap of crash orphans for one peer conversation. Never
  /// throws; upload failures surface through the upload itself.
  Future<void> cleanupOrphans(
    String peer, {
    Duration maxAge = const Duration(hours: 1),
  }) async {
    try {
      final objects = await storage.listDocObjects('$owner/$peer');
      final orphans = findOrphanPrefixes(
        objects,
        now: DateTime.now(),
        maxAge: maxAge,
      );
      if (orphans.isEmpty) return;
      await storage.remove([
        for (final p in orphans)
          for (final o in objects)
            if (o.key.startsWith('$p/')) o.key,
      ]);
    } catch (_) {
      // Orphan cleanup must never block sending.
    }
  }

  Future<String> upload(
    File file,
    String peer, {
    required String name,
    TransferControl? control,
    void Function(double)? onProgress,
    bool forwarded = false,
  }) async {
    if (![
      owner,
      peer,
    ].every((id) => RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id))) {
      throw ArgumentError('Invalid recipient');
    }
    await cleanupOrphans(peer);
    final size = await file.length();
    if (size > maxBytes) {
      throw StateError('Documents must be 200 MB or smaller.');
    }
    final random = Random.secure();
    final id = base64UrlEncode(List.generate(18, (_) => random.nextInt(256)));
    final prefix = '$owner/$peer/$id';
    final uploaded = <String>[];
    final parts = <Map<String, dynamic>>[];
    final source = await file.open();
    var total = 0;
    try {
      while (total < size) {
        control?.check();
        final clear = await source.read(min(chunkBytes, size - total));
        if (clear.isEmpty) throw StateError('File changed while reading.');
        final sealed = await MediaSeal.seal(clear);
        final path = '$prefix/${parts.length}.enc';
        uploaded.add(path);
        await storage.put(path, sealed.cipher);
        parts.add({
          'path': path,
          'key': base64Encode(sealed.key),
          'nonce': base64Encode(sealed.nonce),
          'bytes': clear.length,
        });
        total += clear.length;
        onProgress?.call(size == 0 ? 1 : total / size);
      }
      control?.check();
      if (await file.length() != size) {
        throw StateError('File changed while uploading.');
      }
      final manifest = await MediaSeal.seal(
        Uint8List.fromList(
          utf8.encode(jsonEncode({'v': 1, 'bytes': size, 'parts': parts})),
        ),
      );
      final path = '$prefix/manifest.enc';
      uploaded.add(path);
      await storage.put(path, manifest.cipher);
      control?.check();
      onProgress?.call(1);
      return encodeDocumentBody(
        path,
        safeName(name),
        size,
        key: base64Encode(manifest.key),
        nonce: base64Encode(manifest.nonce),
        fwd: forwarded,
      );
    } catch (_) {
      try {
        await storage.remove(uploaded);
      } catch (_) {}
      rethrow;
    } finally {
      await source.close();
    }
  }

  Future<File> download(
    MediaBody body,
    File output, {
    TransferControl? control,
    void Function(double)? onProgress,
  }) async {
    if (!body.isDocument || !body.isSealed || body.path == null) {
      throw StateError('Invalid document reference.');
    }
    final encrypted = await storage.get(body.path!);
    if (encrypted.length > 1024 * 1024) {
      throw StateError('Invalid document manifest.');
    }
    final clear = await MediaSeal.open(
      cipher: encrypted,
      key: base64Decode(body.key!),
      nonce: base64Decode(body.nonce!),
    );
    final manifest = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
    final size = manifest['bytes'];
    final parts = manifest['parts'];
    if (manifest['v'] != 1 ||
        size is! int ||
        size < 0 ||
        size > maxBytes ||
        size != body.byteLength ||
        parts is! List ||
        parts.length != (size / chunkBytes).ceil()) {
      throw StateError('Invalid document manifest.');
    }
    final prefix = body.path!.substring(0, body.path!.lastIndexOf('/'));
    var total = 0;
    final sink = await output.open(mode: FileMode.write);
    var completed = false;
    try {
      for (var i = 0; i < parts.length; i++) {
        control?.check();
        final part = parts[i] as Map;
        final expected = min(chunkBytes, size - total);
        if (part['path'] != '$prefix/$i.enc' || part['bytes'] != expected) {
          throw StateError('Invalid document chunk.');
        }
        final cipher = await storage.get(part['path'] as String);
        if (cipher.length != expected + 16) {
          throw StateError('Truncated document chunk.');
        }
        final plain = await MediaSeal.open(
          cipher: cipher,
          key: base64Decode(part['key'] as String),
          nonce: base64Decode(part['nonce'] as String),
        );
        await sink.writeFrom(plain);
        total += plain.length;
        onProgress?.call(size == 0 ? 1 : total / size);
      }
      control?.check();
      if (total != size) throw StateError('Incomplete document.');
      await sink.flush();
      completed = true;
      return output;
    } finally {
      await sink.close();
      if (!completed && await output.exists()) await output.delete();
    }
  }
}
