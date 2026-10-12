import 'dart:convert';

/// Body-level encoding inside the Signal plaintext. The envelope transport
/// is untouched: text stays raw text (backwards compatible), image messages
/// are compact JSON carrying a storage path plus an optional caption.
class MediaBody {
  const MediaBody.text(this.text, {this.forwarded = false})
    : kind = 'text',
      removed = false,
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
      choices = null,
      refId = null,
      quoteName = null,
      quoteText = null,
      target = null;
  const MediaBody.image({required this.path, this.text = '', this.key, this.nonce, this.forwarded = false})
    : kind = 'image',
      removed = false,
      thumbPath = null,
      thumbKey = null,
      thumbNonce = null,
      durationSec = 0,
      pollId = null,
      question = null,
      options = null,
      multi = false,
      choices = null,
      refId = null,
      quoteName = null,
      quoteText = null,
      target = null;
  const MediaBody.video({
    required this.path,
    this.text = '',
    this.key,
    this.nonce,
    this.thumbPath,
    this.thumbKey,
    this.thumbNonce,
    this.durationSec = 0,
    this.forwarded = false,
  }) : kind = 'video',
      removed = false,
       pollId = null,
       question = null,
       options = null,
       multi = false,
       choices = null,
       refId = null,
       quoteName = null,
       quoteText = null,
       target = null;
  const MediaBody.poll({
    required this.pollId,
    required this.question,
    required this.options,
    this.multi = false,
    this.forwarded = false,
  }) : kind = 'poll',
      removed = false,
       text = '',
       path = null,
       key = null,
       nonce = null,
       thumbPath = null,
       thumbKey = null,
       thumbNonce = null,
       durationSec = 0,
       choices = null,
       refId = null,
       quoteName = null,
       quoteText = null,
       target = null;
  const MediaBody.vote({required this.pollId, required this.choices})
    : kind = 'vote',
      removed = false,
      forwarded = false,
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
      multi = false,
      refId = null,
      quoteName = null,
      quoteText = null,
      target = null;
  const MediaBody.reply({
    required this.refId,
    required this.text,
    required this.quoteName,
    required this.quoteText,
    this.forwarded = false,
  }) : kind = 'reply',
      removed = false,
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
       choices = null,
       target = null;
  const MediaBody.delete({required this.target})
    : kind = 'del',
      removed = false,
      forwarded = false,
      text = '',
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
      choices = null,
      refId = null,
      quoteName = null,
      quoteText = null;
  const MediaBody.tomb()
    : kind = 'tomb',
      removed = false,
      forwarded = false,
      text = '',
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
      choices = null,
      refId = null,
      quoteName = null,
      quoteText = null,
      target = null;
  const MediaBody.react({required this.target, required this.text, this.removed = false})
    : kind = 'react',
      forwarded = false,
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
      choices = null,
      refId = null,
      quoteName = null,
      quoteText = null;
  const MediaBody.edit({required this.target, required this.text})
    : kind = 'edit',
      removed = false,
      forwarded = false,
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
      choices = null,
      refId = null,
      quoteName = null,
      quoteText = null;
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

  /// Reply quote ([refId] identifies the quoted message) and delete
  /// tombstones ([target] identifies the removed message).
  final String? refId;
  final String? quoteName;
  final String? quoteText;
  final String? target;

  /// Forwarded marker, authenticated inside the encrypted body.
  final bool forwarded;

  /// Reaction clear flag (kind 'react' only).
  final bool removed;
  bool get isImage => kind == 'image';
  bool get isVideo => kind == 'video';
  bool get isPoll => kind == 'poll';
  bool get isVote => kind == 'vote';
  bool get isReply => kind == 'reply';
  bool get isDelete => kind == 'del';
  bool get isTombstone => kind == 'tomb';
  bool get isReact => kind == 'react';
  bool get isEdit => kind == 'edit';

  /// Text and quoted replies support in-place correction.
  bool get isEditable => kind == 'text' || kind == 'reply';

  /// Control rows travel the transport but never render as bubbles.
  bool get isControl =>
      isVote || isDelete || isTombstone || isReact || isEdit;
  bool get isSealed => key != null && nonce != null;

  /// Re-encodes this body with the forwarded flag set (WhatsApp
  /// "Forwarded" label). Text bodies gain a JSON envelope; media and
  /// polls keep every field.
  String get forwardedBody {
    switch (kind) {
      case 'image':
        return encodeImageBody(
          path ?? '',
          text,
          key: key,
          nonce: nonce,
          fwd: true,
        );
      case 'video':
        return encodeVideoBody(
          path ?? '',
          text,
          key: key,
          nonce: nonce,
          thumbPath: thumbPath,
          thumbKey: thumbKey,
          thumbNonce: thumbNonce,
          durationSec: durationSec,
          fwd: true,
        );
      case 'poll':
        return encodePollBody(
          pollId ?? '',
          question ?? '',
          options ?? const [],
          multi: multi,
          fwd: true,
        );
      case 'reply':
        // A quote from another conversation should not disclose its author
        // or create a reference that cannot resolve in the destination.
        return encodeTextBody(text, fwd: true);
      case 'vote':
      case 'del':
      case 'tomb':
      case 'react':
      case 'edit':
        throw StateError('Control messages cannot be forwarded.');
      default:
        return encodeTextBody(text, fwd: true);
    }
  }

  /// Re-encodes an editable body with replacement text, preserving the
  /// quote context and forwarded flag.
  String editedBody(String newText) {
    final clean = newText.trim();
    if (clean.isEmpty || clean.length > 4000) {
      throw StateError('Edited text must contain 1–4000 characters.');
    }
    if (kind == 'reply') {
      return encodeReplyBody(
        refId ?? '',
        clean,
        quoteName ?? '',
        quoteText ?? '',
        fwd: forwarded,
      );
    }
    if (kind == 'text') {
      return encodeTextBody(clean, fwd: forwarded);
    }
    throw StateError('Only text messages can be edited.');
  }
}

/// Plain-text body with an optional forwarded flag. Raw legacy text stays
/// untouched; only flagged content uses this envelope.
String encodeTextBody(String text, {bool fwd = false}) => fwd || text.startsWith('{')
    ? jsonEncode({'t': 'txt', 'b': text, if (fwd) 'fwd': true})
    : text;

/// Quoted reply: [refId] identifies the quoted message for future jumps.
String encodeReplyBody(
  String refId,
  String text,
  String quoteName,
  String quoteText, {
  bool fwd = false,
}) => jsonEncode({
  't': 'reply',
  'ref': refId,
  'b': text,
  'qn': quoteName,
  'qt': quoteText,
  if (fwd) 'fwd': true,
});

/// Delete-for-everyone marker naming the removed message id.
String encodeDeleteBody(String target) => jsonEncode({
  't': 'del',
  'target': target,
});

/// Reaction set/remove: [remove] true clears [emoji] from the target.
/// Explicit state (not a toggle) so redelivery is idempotent.
String encodeReactBody(String target, String emoji, {bool remove = false}) =>
    jsonEncode({
      't': 'react',
      'target': target,
      'e': emoji,
      if (remove) 'rm': true,
    });

/// In-place correction naming the original message id.
String encodeEditBody(String target, String text) => jsonEncode({
  't': 'edit',
  'target': target,
  'b': text,
});

/// Local tombstone rendered where a deleted message stood.
String encodeTombstoneBody() => jsonEncode({'t': 'tomb'});

/// Encodes an image reference. Paths are `<sender>/<recipient>/<file>`
/// inside the private `chat-media` bucket and stay well under the 8KB
/// envelope cap. [key]/[nonce] carry the sealed file key material; omit
/// them only for legacy unsealed uploads.
String encodeImageBody(
  String path,
  String caption, {
  String? key,
  String? nonce,
  bool fwd = false,
}) => jsonEncode({
  't': 'img',
  'path': path,
  'cap': caption,
  'k': ?key,
  'n': ?nonce,
  if (fwd) 'fwd': true,
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
  bool fwd = false,
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
  if (fwd) 'fwd': true,
});

/// Encodes a poll definition. Stays tiny: question + up to 8 short options
/// fit the 8KB envelope with wide margin.
String encodePollBody(
  String pollId,
  String question,
  List<String> options, {
  bool multi = false,
  bool fwd = false,
}) => jsonEncode({
  't': 'poll',
  'id': pollId,
  'q': question,
  'opts': options,
  'multi': multi,
  if (fwd) 'fwd': true,
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
/// plain text, so every historical message keeps rendering. A top-level
/// forwarded flag survives on every kind.
MediaBody parseMessageBody(String raw) {
  if (!raw.startsWith('{')) return MediaBody.text(raw);
  try {
    final decoded = jsonDecode(raw);
    final fwd = decoded is Map<String, dynamic> && decoded['fwd'] == true;
    if (decoded is Map<String, dynamic> && decoded['t'] == 'txt') {
      final b = decoded['b'];
      if (b is String) return MediaBody.text(b, forwarded: fwd);
    }
    if (decoded is Map<String, dynamic> &&
        decoded['t'] == 'img' &&
        decoded['path'] is String &&
        (decoded['path'] as String).isNotEmpty) {
      final caption = decoded['cap'];
      final key = decoded['k'];
      final nonce = decoded['n'];
      return MediaBody.image(
          forwarded: fwd,
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
          forwarded: fwd,
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
            forwarded: fwd,
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
    if (decoded is Map<String, dynamic> && decoded['t'] == 'reply') {
      final ref = decoded['ref'];
      final b = decoded['b'];
      final qn = decoded['qn'];
      final qt = decoded['qt'];
      if (ref is String &&
          ref.isNotEmpty &&
          b is String &&
          qn is String &&
          qt is String) {
        return MediaBody.reply(
            forwarded: fwd,
            refId: ref,
            text: b,
            quoteName: qn,
            quoteText: qt,
        );
      }
    }
    if (decoded is Map<String, dynamic> && decoded['t'] == 'del') {
      final target = decoded['target'];
      if (target is String && target.isNotEmpty) {
        return MediaBody.delete(target: target);
      }
    }
    if (decoded is Map<String, dynamic> && decoded['t'] == 'react') {
      final target = decoded['target'];
      final emoji = decoded['e'];
      if (target is String &&
          target.isNotEmpty &&
          emoji is String &&
          emoji.isNotEmpty &&
          emoji.runes.length <= 8) {
        return MediaBody.react(
          target: target,
          text: emoji,
          removed: decoded['rm'] == true,
        );
      }
    }
    if (decoded is Map<String, dynamic> && decoded['t'] == 'edit') {
      final target = decoded['target'];
      final b = decoded['b'];
      if (target is String &&
          target.isNotEmpty &&
          b is String &&
          b.trim().isNotEmpty &&
          b.length <= 4000) {
        return MediaBody.edit(target: target, text: b);
      }
    }
    if (decoded is Map<String, dynamic> && decoded['t'] == 'tomb') {
      return const MediaBody.tomb();
    }
  } catch (_) {}
  return MediaBody.text(raw);
}
