import 'package:flutter_test/flutter_test.dart';
import 'package:open_chat/src/media/media_message.dart';

void main() {
  test('plain text passes through untouched', () {
    final body = parseMessageBody('Hello with emoji 🎉');
    expect(body.kind, 'text');
    expect(body.text, 'Hello with emoji 🎉');
    expect(body.path, isNull);
  });

  test('legacy JSON-looking text stays text', () {
    final body = parseMessageBody('{"not": "an image"}');
    expect(body.kind, 'text');
  });

  test('corrupt JSON stays text', () {
    final body = parseMessageBody('{oops');
    expect(body.kind, 'text');
  });

  test('image round-trips path and caption', () {
    const path = 'sender-id/peer-id/123-photo.jpg';
    final raw = encodeImageBody(path, 'Beach day 📷');
    final body = parseMessageBody(raw);
    expect(body.kind, 'image');
    expect(body.isImage, isTrue);
    expect(body.path, path);
    expect(body.text, 'Beach day 📷');
  });

  test('image without caption decodes to empty text', () {
    final body = parseMessageBody(encodeImageBody('a/b/c.jpg', ''));
    expect(body.kind, 'image');
    expect(body.text, isEmpty);
  });

  test('image body fits the 8KB envelope cap', () {
    final raw = encodeImageBody(
      '${'u' * 36}/${'u' * 36}/${'f' * 40}.jpg',
      'x' * 200,
    );
    expect(raw.length, lessThan(8192));
  });

  test('sealed image round-trips key material', () {
    final raw = encodeImageBody(
      'a/b/c.enc',
      'secret pic',
      key: 'a2V5',
      nonce: 'bm9uY2U',
    );
    final body = parseMessageBody(raw);
    expect(body.kind, 'image');
    expect(body.isSealed, isTrue);
    expect(body.key, 'a2V5');
    expect(body.nonce, 'bm9uY2U');
    expect(raw.length, lessThan(8192));
  });

  test('legacy image without key material stays unsealed', () {
    final body = parseMessageBody(encodeImageBody('a/b/c.jpg', 'old'));
    expect(body.kind, 'image');
    expect(body.isSealed, isFalse);
  });
}
