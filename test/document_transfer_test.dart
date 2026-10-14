import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_chat/src/media/document_transfer.dart';
import 'package:open_chat/src/media/media_message.dart';

void main() {
  test('safeName strips paths, illegal chars, and caps length', () {
    expect(DocumentTransfer.safeName('a/b\\evil<name>?.pdf'), 'evil_name__.pdf');
    expect(DocumentTransfer.safeName('..'), 'Document');
    expect(DocumentTransfer.safeName(''), 'Document');
    final long = '${'x' * 300}.pdf';
    expect(DocumentTransfer.safeName(long).length, lessThanOrEqualTo(200));
  });

  test('document body round-trips name, size, and keys', () {
    final raw = encodeDocumentBody('alice/bob/id/manifest.enc', 'Report Q3.pdf', 12345, key: 'a2V5', nonce: 'bm9uY2U');
    final body = parseMessageBody(raw);
    expect(body.isDocument, isTrue);
    expect(body.isSealed, isTrue);
    expect(body.fileName, 'Report Q3.pdf');
    expect(body.byteLength, 12345);
    expect(body.path, 'alice/bob/id/manifest.enc');
    expect(raw.length, lessThan(8192));
  });

  test('document chunk count matches 4 MiB ceiling', () {
    int chunks(int size) => (size / DocumentTransfer.chunkBytes).ceil();
    expect(chunks(0), 0);
    expect(chunks(1), 1);
    expect(chunks(DocumentTransfer.chunkBytes), 1);
    expect(chunks(DocumentTransfer.chunkBytes + 1), 2);
    expect(chunks(DocumentTransfer.maxBytes), 50);
  });

  test('orphan detection reaps only manifest-less prefixes older than maxAge', () {
    final now = DateTime.utc(2026, 10, 13, 12);
    final old = now.subtract(const Duration(hours: 2));
    final fresh = now.subtract(const Duration(minutes: 5));
    final objects = [
      StoredObject('alice/bob/orphan/0.enc', old),
      StoredObject('alice/bob/orphan/1.enc', old),
      StoredObject('alice/bob/done/0.enc', old),
      StoredObject('alice/bob/done/manifest.enc', old),
      StoredObject('alice/bob/active/0.enc', fresh),
      StoredObject('alice/bob/unknown/0.enc', null),
    ];
    expect(
      DocumentTransfer.findOrphanPrefixes(objects, now: now),
      ['alice/bob/orphan'],
    );
    expect(
      DocumentTransfer.findOrphanPrefixes(objects, now: now, maxAge: const Duration(hours: 3)),
      isEmpty,
    );
  });

  test('cleanupOrphans removes only orphan keys and never throws', () async {
    final removed = <String>[];
    final storage = _FakeChunkStorage([
      StoredObject('alice/bob/orphan/0.enc', DateTime.now().subtract(const Duration(hours: 2))),
      StoredObject('alice/bob/done/0.enc', DateTime.now().subtract(const Duration(hours: 2))),
      StoredObject('alice/bob/done/manifest.enc', DateTime.now().subtract(const Duration(hours: 2))),
    ], removed);
    await DocumentTransfer(storage, 'alice').cleanupOrphans('bob');
    expect(removed, ['alice/bob/orphan/0.enc']);
    await DocumentTransfer(_ThrowingChunkStorage(), 'alice').cleanupOrphans('bob');
  });

  test('documents and view-once cannot use generic forward path', () {
    const doc = MediaBody.document(path: 'a/b/manifest.enc', key: 'k', nonce: 'n', metadata: {'name': 'f', 'bytes': 1});
    expect(() => doc.forwardedBody, throwsStateError);
    final once = parseMessageBody('{"t":"img","path":"a/b/c.enc","cap":"","k":"a2V5","n":"bm9uY2U","once":true}');
    expect(once.viewOnce, isTrue);
    expect(() => once.forwardedBody, throwsStateError);
  });
}

class _FakeChunkStorage implements ChunkStorage {
  _FakeChunkStorage(this.objects, this.removed);
  final List<StoredObject> objects;
  final List<String> removed;
  @override
  Future<void> put(String path, Uint8List bytes) async {}
  @override
  Future<Uint8List> get(String path) async => Uint8List(0);
  @override
  Future<void> remove(List<String> paths) async => removed.addAll(paths);
  @override
  Future<List<StoredObject>> listDocObjects(String peerPrefix) async =>
      objects.where((o) => o.key.startsWith(peerPrefix)).toList();
}

class _ThrowingChunkStorage implements ChunkStorage {
  @override
  Future<void> put(String path, Uint8List bytes) async => throw StateError('down');
  @override
  Future<Uint8List> get(String path) async => throw StateError('down');
  @override
  Future<void> remove(List<String> paths) async => throw StateError('down');
  @override
  Future<List<StoredObject>> listDocObjects(String peerPrefix) async => throw StateError('down');
}
