import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'media_seal.dart';
/// Reference to a sealed upload: object path plus base64 key material that
/// travels inside the Signal-encrypted message.
class SealedUpload {
  const SealedUpload({
    required this.path,
    required this.key,
    required this.nonce,
  });
  final String path;
  final String key;
  final String nonce;
}

/// Reference to a sealed video upload: sealed file + sealed thumbnail,
/// each with its own key pair, plus duration for the bubble.
class SealedVideo {
  const SealedVideo({
    required this.path,
    required this.key,
    required this.nonce,
    required this.thumbPath,
    required this.thumbKey,
    required this.thumbNonce,
  });
  final String path;
  final String key;
  final String nonce;
  final String thumbPath;
  final String thumbKey;
  final String thumbNonce;
}

/// Pilot media transport on the private `chat-media` bucket. Files are
/// AES-256-GCM sealed on-device with a fresh key per file; the server only
/// ever sees ciphertext, and only the two chat parties can even read that.
class ChatMedia {
  ChatMedia(this.client);
  final SupabaseClient client;
  static const bucket = 'chat-media';
  static const maxBytes = 10 * 1024 * 1024;

  /// Uploads an image picked from gallery/camera and returns its object
  /// path `<sender>/<recipient>/<uuid>.jpg`.
  Future<String> uploadImage(File file, String peerId) async {
    final sealed = await uploadSealed(file, peerId);
    return sealed.path;
  }

  /// Seals [file] with a fresh AES-256-GCM key, uploads the ciphertext,
  /// and returns the path plus base64 key material for the message body.
  Future<SealedUpload> uploadSealed(File file, String peerId) async {
    final me = client.auth.currentUser?.id;
    if (me == null) throw const AuthException('Sign in to send images.');
    final bytes = await file.length();
    if (bytes > maxBytes) {
      throw StateError('Image is larger than 10 MB.');
    }
    final plain = await file.readAsBytes();
    final sealed = MediaSeal.seal(plain);
    final name =
        '${DateTime.now().microsecondsSinceEpoch}-${file.uri.pathSegments.last}.enc';
    final path = '$me/$peerId/$name';
    await client.storage
        .from(bucket)
        .uploadBinary(
          path,
          sealed.cipher,
          fileOptions: const FileOptions(upsert: true),
        );
    return SealedUpload(
      path: path,
      key: base64Encode(sealed.key),
      nonce: base64Encode(sealed.nonce),
    );
  }

  /// Downloads and unseals an image. Plaintext only ever lives in memory.
  Future<Uint8List> downloadSealed(
    String path,
    String keyB64,
    String nonceB64,
  ) async {
    final cipher = await client.storage.from(bucket).download(path);
    return MediaSeal.open(
      cipher: cipher,
      key: base64Decode(keyB64),
      nonce: base64Decode(nonceB64),
    );
  }

  /// Raw download for legacy unsealed uploads (no key material).
  Future<Uint8List> downloadRaw(String path) =>
      client.storage.from(bucket).download(path);

  static const maxVideoBytes = 64 * 1024 * 1024;

  /// Seals a video plus a small thumbnail (own key pair each) and uploads
  /// both ciphertexts. WhatsApp-style pilot cap: 64 MB per video.
  Future<SealedVideo> uploadSealedVideo(File file, String peerId) async {
    final me = client.auth.currentUser?.id;
    if (me == null) throw const AuthException('Sign in to send videos.');
    final size = await file.length();
    if (size > maxVideoBytes) {
      throw StateError('Video is larger than 64 MB.');
    }
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final base = file.uri.pathSegments.last;
    Future<SealedUpload> putBytes(Uint8List bytes, String name) async {
      final sealed = MediaSeal.seal(bytes);
      final path = '$me/$peerId/$stamp-$name.enc';
      await client.storage
          .from(bucket)
          .uploadBinary(
            path,
            sealed.cipher,
            fileOptions: const FileOptions(upsert: true),
          );
      return SealedUpload(
        path: path,
        key: base64Encode(sealed.key),
        nonce: base64Encode(sealed.nonce),
      );
    }

    final video = await putBytes(await file.readAsBytes(), base);
    // No thumbnail: the video_thumbnail plugin is unmaintained and breaks
    // the Android build (jcenter/AGP9). The bubble renders a duration tile
    // until a maintained thumbnail solution lands.
    return SealedVideo(
      path: video.path,
      key: video.key,
      nonce: video.nonce,
      thumbPath: '',
      thumbKey: '',
      thumbNonce: '',
    );
  }

  Future<XFile?> pickGalleryVideo() => ImagePicker().pickVideo(
    source: ImageSource.gallery,
    maxDuration: const Duration(minutes: 3),
  );

  Future<XFile?> pickCameraVideo() => ImagePicker().pickVideo(
    source: ImageSource.camera,
    maxDuration: const Duration(minutes: 3),
  );

  /// Short-lived authenticated URL for rendering. Never share or persist it.
  Future<String> displayUrl(String path) =>
      client.storage.from(bucket).createSignedUrl(path, 3600);

  Future<XFile?> pickGalleryImage() => ImagePicker().pickImage(
    source: ImageSource.gallery,
    maxWidth: 1600,
    imageQuality: 85,
  );

  Future<XFile?> pickCameraImage() => ImagePicker().pickImage(
    source: ImageSource.camera,
    maxWidth: 1600,
    imageQuality: 85,
  );
}
