import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_chat/src/media/chat_media.dart';
import 'package:open_chat/src/media/media_message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class MemoryMedia extends ChatMedia {
  MemoryMedia(super.client);
  final downloaded = <String>[];
  final uploaded = <String>[];
  @override
  Future<Uint8List> downloadSealed(
    String path,
    String keyB64,
    String nonceB64, {
    void Function(double)? onProgress,
  }) async {
    downloaded.add(path);
    return Uint8List.fromList([1, 2, 3]);
  }

  @override
  Future<SealedUpload> uploadSealedBytes(
    Uint8List plain,
    String peerId, {
    bool video = false,
    void Function(double)? onProgress,
  }) async {
    expect(plain, [1, 2, 3]);
    uploaded.add(peerId);
    return SealedUpload(
      path: 'me/$peerId/new.enc',
      key: 'fresh-key',
      nonce: 'fresh-nonce',
    );
  }
}

void main() {
  late SupabaseClient client;
  late MemoryMedia media;
  setUp(() {
    client = SupabaseClient('https://example.test', 'test-key');
    media = MemoryMedia(client);
  });
  tearDown(() => client.dispose());

  test(
    'forward media reuploads for recipient and removes old thumbnail keys',
    () async {
      for (final source in [
        const MediaBody.image(
          path: 'alice/me/old.enc',
          text: 'caption',
          key: 'old-key',
          nonce: 'old-nonce',
        ),
        const MediaBody.video(
          path: 'alice/me/old.enc',
          text: 'caption',
          key: 'old-key',
          nonce: 'old-nonce',
          thumbPath: 'old-thumb',
          thumbKey: 'thumb-key',
          thumbNonce: 'thumb-nonce',
          durationSec: 20,
        ),
        const MediaBody.video(
          path: 'alice/me/note.enc',
          text: '',
          key: 'old-key',
          nonce: 'old-nonce',
          durationSec: 20,
          metadata: {'note': true},
        ),
      ]) {
        final forwarded = parseMessageBody(
          await media.forwardBody(source, 'bob'),
        );
        expect(forwarded.path, 'me/bob/new.enc');
        expect(forwarded.key, 'fresh-key');
        expect(forwarded.nonce, 'fresh-nonce');
        expect(forwarded.thumbPath, isNull);
        expect(forwarded.text, source.text);
        expect(forwarded.forwarded, isTrue);
        expect(forwarded.isVideoNote, source.isVideoNote);
      }
      expect(media.downloaded, [
        'alice/me/old.enc',
        'alice/me/old.enc',
        'alice/me/note.enc',
      ]);
      expect(media.uploaded, ['bob', 'bob', 'bob']);
    },
  );

  test('forwarding the same poll twice creates independent ballots', () async {
    const poll = MediaBody.poll(
      pollId: 'old',
      question: 'Ready?',
      options: ['Yes', 'No'],
    );
    final first = parseMessageBody(await media.forwardBody(poll, 'bob'));
    final second = parseMessageBody(await media.forwardBody(poll, 'bob'));
    expect(first.pollId, isNot('old'));
    expect(first.pollId, isNot(second.pollId));
    expect(first.options, poll.options);
    expect(first.forwarded, isTrue);
  });
}
