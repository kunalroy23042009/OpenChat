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

  test('sealed video round-trips all fields', () {
    final raw = encodeVideoBody(
      's/r/v.enc',
      'trip 🎬',
      key: 'a2V5',
      nonce: 'bm9uY2U',
      thumbPath: 's/r/v.thumb.enc',
      thumbKey: 'dGhr',
      thumbNonce: 'dGhu',
      durationSec: 65,
    );
    final body = parseMessageBody(raw);
    expect(body.kind, 'video');
    expect(body.isVideo, isTrue);
    expect(body.isSealed, isTrue);
    expect(body.path, 's/r/v.enc');
    expect(body.thumbPath, 's/r/v.thumb.enc');
    expect(body.thumbKey, 'dGhr');
    expect(body.thumbNonce, 'dGhu');
    expect(body.durationSec, 65);
    expect(body.text, 'trip 🎬');
    expect(raw.length, lessThan(8192));
  });

  test('video without thumbnail still parses', () {
    final body = parseMessageBody(
      encodeVideoBody('s/r/v.enc', '', durationSec: 7),
    );
    expect(body.isVideo, isTrue);
    expect(body.isSealed, isFalse);
    expect(body.thumbPath, isNull);
    expect(body.durationSec, 7);
  });

  test('poll round-trips question, options, and mode', () {
    final raw = encodePollBody(
      'poll-1',
      'Saturday at 10?',
      ['Yes', 'No', 'Maybe'],
    );
    final body = parseMessageBody(raw);
    expect(body.kind, 'poll');
    expect(body.pollId, 'poll-1');
    expect(body.question, 'Saturday at 10?');
    expect(body.options, ['Yes', 'No', 'Maybe']);
    expect(body.multi, isFalse);
    expect(raw.length, lessThan(8192));
  });

  test('malformed polls stay text', () {
    expect(parseMessageBody('{"t":"poll"}').kind, 'text');
    expect(
      parseMessageBody('{"t":"poll","id":"x","q":"y","opts":["one"]}').kind,
      'text',
    );
    expect(
      parseMessageBody('{"t":"vote","id":"x","choices":[]}').kind,
      'text',
    );
  });

  test('tally counts latest ballot per side', () {
    final messages = [
      (text: encodeVoteBody('p', [0]), mine: true),
      (text: encodeVoteBody('p', [1]), mine: false),
      (text: encodeVoteBody('p', [2]), mine: true),
      (text: 'unrelated text', mine: false),
      (text: encodeVoteBody('other', [0]), mine: false),
    ];
    final tally = tallyPoll('p', 3, messages);
    expect(tally.counts, [0, 1, 1]);
    expect(tally.total, 2);
  });

  test('tally ignores out-of-range options', () {
    final messages = [
      (text: encodeVoteBody('p', [0, 9, -1]), mine: false),
    ];
    final tally = tallyPoll('p', 2, messages);
    expect(tally.counts, [1, 0]);
  });
}
