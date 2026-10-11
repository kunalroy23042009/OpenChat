import 'dart:convert';

/// Body-level encoding inside the Signal plaintext. The envelope transport
/// is untouched: text stays raw text (backwards compatible), image messages
/// are compact JSON carrying a storage path plus an optional caption.
class MediaBody {
  const MediaBody.text(this.text)
    : kind = 'text',
      path = null,
      key = null,
      nonce = null;
  const MediaBody.image({required this.path, this.text = '', this.key, this.nonce})
    : kind = 'image';
  final String kind;
  final String text;
  final String? path;

  /// Base64 AES-256-GCM file key/nonce. Absent on legacy unsealed images.
  final String? key;
  final String? nonce;
  bool get isImage => kind == 'image';
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
  } catch (_) {}
  return MediaBody.text(raw);
}
