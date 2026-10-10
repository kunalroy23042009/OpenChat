/// Envelope body codec for the server message transport.
///
 /// The `message_envelopes` table has no message-type column
/// (`protocol_version` is a fixed schema marker), so the Signal message type
/// travels prefixed to the base64 body as `type.body`. Base64 output never
/// contains `.`, making the split unambiguous.
class EnvelopeCodec {
  /// Packs a Signal message type and its base64 body for transport.
  static String encode(int type, String body) => '$type.$body';

  /// Splits a stored envelope into `(type, body)` candidates for decryption.
  ///
  /// Current rows carry the `type.` prefix. Legacy rows without a parseable
  /// prefix fall back to the prekey type first, then whisper.
  static List<MapEntry<int, String>> candidates(String raw) {
    final separator = raw.indexOf('.');
    if (separator > 0) {
      final type = int.tryParse(raw.substring(0, separator));
      if (type != null) return [MapEntry(type, raw.substring(separator + 1))];
    }
    return [MapEntry(3, raw), MapEntry(2, raw)];
  }
}
