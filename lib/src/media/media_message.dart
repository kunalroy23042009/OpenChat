import 'dart:convert';

/// Body-level encoding inside the Signal plaintext. The envelope transport
/// is untouched: text stays raw text (backwards compatible), image messages
/// are compact JSON carrying a storage path plus an optional caption.
class MediaBody {
  const MediaBody.text(this.text)
    : kind = 'text',
      path = null,
      key = null,
      nonce = null,
      thumbPath = null,
      thumbKey = null,
      thumbNonce = null,
      durationSec = 0,
      pollId = null,
      question = null,
      options = null,
      multi = false,
      choices = null;
  const MediaBody.image({required this.path, this.text = '', this.key, this.nonce})
    : kind = 'image',
      thumbPath = null,
      thumbKey = null,
      thumbNonce = null,
      durationSec = 0,
      pollId = null,
      question = null,
      options = null,
      multi = false,
      choices = null;
  const MediaBody.video({
    required this.path,
    this.text = '',
    this.key,
    this.nonce,
    this.thumbPath,
    this.thumbKey,
    this.thumbNonce,
    this.durationSec = 0,
  }) : kind = 'video',
       pollId = null,
       question = null,
       options = null,
       multi = false,
       choices = null;
  const MediaBody.poll({
    required this.pollId,
    required this.question,
    required this.options,
    this.multi = false,
  }) : kind = 'poll',
       text = '',
       path = null,
       key = null,
       nonce = null,
       thumbPath = null,
       thumbKey = null,
       thumbNonce = null,
       durationSec = 0,
       choices = null;
  const MediaBody.vote({required this.pollId, required this.choices})
    : kind = 'vote',
      text = '',
      path = null,
      key = null,
      nonce = null,
      thumbPath = null,
      thumbKey = null,
      thumbNonce = null,
      durationSec = 0,
      question = null,
      options = null,
      multi = false;
  final String kind;
  final String text;
  final String? path;

  /// Base64 AES-256-GCM file key/nonce. Absent on legacy unsealed uploads.
  final String? key;
  final String? nonce;

  /// Sealed video thumbnail (separate key pair) + duration for the bubble.
  final String? thumbPath;
  final String? thumbKey;
  final String? thumbNonce;
  final int durationSec;

  /// Poll definition / ballot. [options] are the answer choices,
  /// [choices] a voter's selected indices. One stored vote per sender wins.
  final String? pollId;
  final String? question;
  final List<String>? options;
  final bool multi;
  final List<int>? choices;
  bool get isImage => kind == 'image';
  bool get isVideo => kind == 'video';
  bool get isPoll => kind == 'poll';
  bool get isVote => kind == 'vote';
  bool get isSealed => key != null && nonce != null;
}

/// Encodes an image reference. Paths are `<sender>/<recipient>/<file>`
/// inside the private `chat-media` bucket and stay well under the 8KB
/// envelope cap. [key]/[nonce] carry the sealed file key material; omit
/// them only for legacy unsealed uploads.
String encodeImageBody(
  String path,
  String caption, {
  String? key,
  String? nonce,
}) => jsonEncode({
  't': 'img',
  'path': path,
  'cap': caption,
  'k': ?key,
  'n': ?nonce,
});

String encodeVideoBody(
  String path,
  String caption, {
  String? key,
  String? nonce,
  String? thumbPath,
  String? thumbKey,
  String? thumbNonce,
  int durationSec = 0,
}) => jsonEncode({
  't': 'vid',
  'path': path,
  'cap': caption,
  'k': ?key,
  'n': ?nonce,
  'tp': ?thumbPath,
  'tk': ?thumbKey,
  'tn': ?thumbNonce,
  'dur': durationSec,
});

/// Encodes a poll definition. Stays tiny: question + up to 8 short options
/// fit the 8KB envelope with wide margin.
String encodePollBody(
  String pollId,
  String question,
  List<String> options, {
  bool multi = false,
}) => jsonEncode({
  't': 'poll',
  'id': pollId,
  'q': question,
  'opts': options,
  'multi': multi,
});

/// Encodes one ballot for [pollId]. Sending again replaces the earlier
/// ballot from the same sender (latest wins).
String encodeVoteBody(String pollId, List<int> choices) => jsonEncode({
  't': 'vote',
  'id': pollId,
  'choices': choices,
});

/// Live tally for one poll, aggregated from stored message bodies.
/// Latest ballot per side (mine / peer) wins; unknown options are ignored.
class PollTally {
  PollTally({required this.optionCount});
  final int optionCount;
  final List<int> mine = [];
  final List<int> peer = [];

  void addBallot({required bool fromMe, required List<int> choices}) {
    final clean = choices
        .where((c) => c >= 0 && c < optionCount)
        .toSet()
        .toList();
    final target = fromMe ? mine : peer;
    target
      ..clear()
      ..addAll(clean);
  }

  List<int> get counts {
    final result = List<int>.filled(optionCount, 0);
    for (final c in mine) {
      result[c]++;
    }
    for (final c in peer) {
      result[c]++;
    }
    return result;
  }

  int get total => mine.length + peer.length;
}

/// Aggregates every ballot stored for [pollId] across [messages], where
/// each entry carries the raw body text and its side.
PollTally tallyPoll(
  String pollId,
  int optionCount,
  List<({String text, bool mine})> messages,
) {
  final tally = PollTally(optionCount: optionCount);
  for (final m in messages) {
    final body = parseMessageBody(m.text);
    if (body.isVote && body.pollId == pollId && body.choices != null) {
      tally.addBallot(fromMe: m.mine, choices: body.choices!);
    }
  }
  return tally;
}

/// Parses stored/decrypted bodies. Anything that is not our JSON shape is
/// plain text, so every historical message keeps rendering.
MediaBody parseMessageBody(String raw) {
  if (!raw.startsWith('{')) return MediaBody.text(raw);
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic> &&
        decoded['t'] == 'img' &&
        decoded['path'] is String &&
        (decoded['path'] as String).isNotEmpty) {
      final caption = decoded['cap'];
      final key = decoded['k'];
      final nonce = decoded['n'];
      return MediaBody.image(
        path: decoded['path'] as String,
        text: caption is String ? caption : '',
        key: key is String && key.isNotEmpty ? key : null,
        nonce: nonce is String && nonce.isNotEmpty ? nonce : null,
      );
    }
    if (decoded is Map<String, dynamic> &&
        decoded['t'] == 'vid' &&
        decoded['path'] is String &&
        (decoded['path'] as String).isNotEmpty) {
      String? str(Object? v) =>
          v is String && v.isNotEmpty ? v : null;
      final dur = decoded['dur'];
      return MediaBody.video(
        path: decoded['path'] as String,
        text: decoded['cap'] is String ? decoded['cap'] as String : '',
        key: str(decoded['k']),
        nonce: str(decoded['n']),
        thumbPath: str(decoded['tp']),
        thumbKey: str(decoded['tk']),
        thumbNonce: str(decoded['tn']),
        durationSec: dur is int ? dur : 0,
      );
    }
    if (decoded is Map<String, dynamic> && decoded['t'] == 'poll') {
      final id = decoded['id'];
      final q = decoded['q'];
      final opts = decoded['opts'];
      if (id is String &&
          id.isNotEmpty &&
          q is String &&
          q.isNotEmpty &&
          opts is List &&
          opts.length >= 2 &&
          opts.length <= 8 &&
          opts.every(
            (o) => o is String && o.isNotEmpty && o.length <= 100,
          )) {
        return MediaBody.poll(
          pollId: id,
          question: q,
          options: opts.cast<String>(),
          multi: decoded['multi'] == true,
        );
      }
    }
    if (decoded is Map<String, dynamic> && decoded['t'] == 'vote') {
      final id = decoded['id'];
      final choices = decoded['choices'];
      if (id is String &&
          id.isNotEmpty &&
          choices is List &&
          choices.isNotEmpty &&
          choices.every((c) => c is int)) {
        return MediaBody.vote(
          pollId: id,
          choices: choices.cast<int>(),
        );
      }
    }
  } catch (_) {}
  return MediaBody.text(raw);
}
