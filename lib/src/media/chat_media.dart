import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../backup/chat_backup.dart';
import '../chat_preferences.dart';
import '../security/app_lock.dart';
import 'media_seal.dart';
import 'media_message.dart';
import 'resumable_transfer.dart';

/// Internal defaults from build-time env (set by `flutter build --dart-define`).
const _defaultSupabaseUrl = String.fromEnvironment('SUPABASE_URL');
const _defaultSupabaseKey = String.fromEnvironment('SUPABASE_ANON_KEY');

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
  ChatMedia(
    this.client, {
    this.preferences,
    String? supabaseUrl,
    String? supabaseKey,
  }) {
    _checkpoints = preferences != null
        ? TransferCheckpointManager(preferences!)
        : null;
    _supabaseUrl = supabaseUrl ?? _defaultSupabaseUrl;
    _supabaseKey = supabaseKey ?? _defaultSupabaseKey;
  }
  final SupabaseClient client;
  final SharedPreferences? preferences;
  late final TransferCheckpointManager? _checkpoints;
  late final String _supabaseUrl;
  late final String _supabaseKey;
  static const bucket = 'chat-media';
  static const maxBytes = 10 * 1024 * 1024;

  /// New object, new key, new recipient path. Reusing the source path would
  /// deny the next recipient access under the private bucket's RLS policy.
  Future<SealedUpload> uploadSealedBytes(
    Uint8List plain,
    String peerId, {
    bool video = false,
    void Function(double progress)? onProgress,
  }) async {
    final me = client.auth.currentUser?.id;
    if (me == null) throw const AuthException('Sign in to share media.');
    if (plain.length > (video ? maxVideoBytes : maxBytes)) {
      throw StateError('Media exceeds the upload limit.');
    }
    final sealed = await MediaSeal.seal(plain);
    final random = Random.secure();
    final name = base64UrlEncode(
      List<int>.generate(18, (_) => random.nextInt(256)),
    );
    final path = '$me/$peerId/$name.enc';

    // Use resumable uploader if checkpoints available
    if (_checkpoints != null) {
      final uploader = ResumableUploader(
        client: client,
        bucket: bucket,
        checkpoints: _checkpoints,
      );
      await uploader.upload(
        path,
        sealed.cipher,
        onProgress: (p) => onProgress?.call(0.1 + 0.9 * p),
      );
    } else {
      onProgress?.call(0.1);
      await client.storage.from(bucket).uploadBinary(path, sealed.cipher);
      onProgress?.call(1.0);
    }
    return SealedUpload(
      path: path,
      key: base64Encode(sealed.key),
      nonce: base64Encode(sealed.nonce),
    );
  }

  Future<String> forwardBody(MediaBody body, String peerId) async {
    if (body.viewOnce) throw StateError('View-once media cannot be forwarded.');
    if (body.isDocument) {
      throw StateError('Documents must be re-uploaded via DocumentTransfer.');
    }
    if (body.isImage || body.isVideo || body.isVoice) {
      if (body.path == null || body.path!.isEmpty) {
        throw StateError('Missing media.');
      }
      if ((body.key == null) != (body.nonce == null)) {
        throw StateError('Incomplete media key.');
      }
      final plain = body.isSealed
          ? await downloadSealed(body.path!, body.key!, body.nonce!)
          : await downloadRaw(body.path!);
      final upload = await uploadSealedBytes(
        plain,
        peerId,
        video: body.isVideo,
      );
      if (body.isVoice) {
        return encodeVoiceBody(
          upload.path,
          body.durationSec,
          key: upload.key,
          nonce: upload.nonce,
          waveform: body.waveform,
          transcript: body.transcript,
          fwd: true,
        );
      }
      if (body.isImage) {
        return encodeImageBody(
          upload.path,
          body.text,
          key: upload.key,
          nonce: upload.nonce,
          fwd: true,
        );
      }
      // The duration tile works without a thumbnail; do not disclose an
      // old thumbnail path/key to a third participant.
      return encodeVideoBody(
        upload.path,
        body.text,
        key: upload.key,
        nonce: upload.nonce,
        durationSec: body.durationSec,
        videoNote: body.isVideoNote,
        fwd: true,
      );
    }
    if (body.isPoll) {
      final random = Random.secure();
      final id = base64UrlEncode(
        List<int>.generate(18, (_) => random.nextInt(256)),
      );
      return encodePollBody(
        id,
        body.question!,
        body.options!,
        multi: body.multi,
        fwd: true,
      );
    }
    return body.forwardedBody;
  }

  /// Seals [file] with a fresh AES-256-GCM key, uploads the ciphertext,
  /// and returns the path plus base64 key material for the message body.
  Future<SealedUpload> uploadSealed(
    File file,
    String peerId, {
    void Function(double progress)? onProgress,
  }) async {
    final me = client.auth.currentUser?.id;
    if (me == null) throw const AuthException('Sign in to send images.');
    final bytes = await file.length();
    if (bytes > maxBytes) {
      throw StateError('Image is larger than 10 MB.');
    }
    final plain = await file.readAsBytes();
    final sealed = await MediaSeal.seal(plain);
    onProgress?.call(0.1);
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
    onProgress?.call(1.0);
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
    String nonceB64, {
    void Function(double progress)? onProgress,
  }) async {
    onProgress?.call(0.1);
    Uint8List cipher;
    try {
      if (_checkpoints != null) {
        final size = await _getObjectSize(path);
        if (size > 0) {
          final downloader = ResumableDownloader(
            client: client,
            bucket: bucket,
            checkpoints: _checkpoints,
            supabaseUrl: _supabaseUrl,
            supabaseKey: _supabaseKey,
          );
          cipher = await downloader.download(
            path,
            size,
            onProgress: (p) => onProgress?.call(0.1 + 0.7 * p),
          );
        } else {
          cipher = await client.storage.from(bucket).download(path);
          onProgress?.call(0.8);
        }
      } else {
        cipher = await client.storage.from(bucket).download(path);
        onProgress?.call(0.8);
      }
    } catch (_) {
      final restored = await ChatBackup.restoreMediaBytes(client, path);
      if (restored == null) rethrow;
      cipher = restored;
      onProgress?.call(0.8);
    }
    final plain = MediaSeal.open(
      cipher: cipher,
      key: base64Decode(keyB64),
      nonce: base64Decode(nonceB64),
    );
    onProgress?.call(1.0);
    return plain;
  }

  /// Raw download for legacy unsealed uploads (no key material).
  Future<Uint8List> downloadRaw(
    String path, {
    void Function(double progress)? onProgress,
  }) async {
    onProgress?.call(0.1);
    try {
      if (_checkpoints != null) {
        final size = await _getObjectSize(path);
        if (size > 0) {
          final downloader = ResumableDownloader(
            client: client,
            bucket: bucket,
            checkpoints: _checkpoints,
            supabaseUrl: _supabaseUrl,
            supabaseKey: _supabaseKey,
          );
          final bytes = await downloader.download(
            path,
            size,
            onProgress: (p) => onProgress?.call(0.1 + 0.9 * p),
          );
          return bytes;
        }
      }
      final bytes = await client.storage.from(bucket).download(path);
      onProgress?.call(1.0);
      return bytes;
    } catch (_) {
      final restored = await ChatBackup.restoreMediaBytes(client, path);
      if (restored == null) rethrow;
      onProgress?.call(1.0);
      return restored;
    }
  }

  /// Get object size via HEAD request
  Future<int> _getObjectSize(String path) async {
    try {
      final url = '$_supabaseUrl/storage/v1/object/$bucket/$path';
      final token = client.auth.currentSession?.accessToken ?? '';
      final response = await http.head(
        Uri.parse(url),
        headers: {'Authorization': 'Bearer $token', 'apikey': _supabaseKey},
      );
      if (response.statusCode == 200) {
        final contentLength = response.headers['content-length'];
        if (contentLength != null) {
          return int.parse(contentLength);
        }
      }
    } catch (_) {
      // Ignore and fall back to simple download
    }
    return 0;
  }

  static const maxVideoBytes = 64 * 1024 * 1024;

  /// Downloads and unseals a video. Plaintext only ever lives in memory.
  Future<Uint8List> downloadSealedVideo(
    String path,
    String keyB64,
    String nonceB64, {
    void Function(double progress)? onProgress,
  }) async {
    onProgress?.call(0.1);
    Uint8List cipher;
    try {
      if (_checkpoints != null) {
        final size = await _getObjectSize(path);
        if (size > 0) {
          final downloader = ResumableDownloader(
            client: client,
            bucket: bucket,
            checkpoints: _checkpoints,
            supabaseUrl: _supabaseUrl,
            supabaseKey: _supabaseKey,
          );
          cipher = await downloader.download(
            path,
            size,
            onProgress: (p) => onProgress?.call(0.1 + 0.7 * p),
          );
        } else {
          cipher = await client.storage.from(bucket).download(path);
          onProgress?.call(0.8);
        }
      } else {
        cipher = await client.storage.from(bucket).download(path);
        onProgress?.call(0.8);
      }
    } catch (_) {
      final restored = await ChatBackup.restoreMediaBytes(client, path);
      if (restored == null) rethrow;
      cipher = restored;
      onProgress?.call(0.8);
    }
    final plain = MediaSeal.open(
      cipher: cipher,
      key: base64Decode(keyB64),
      nonce: base64Decode(nonceB64),
    );
    onProgress?.call(1.0);
    return plain;
  }

  /// Seals a video plus a small thumbnail (own key pair each) and uploads
  /// both ciphertexts. WhatsApp-style pilot cap: 64 MB per video.
  Future<SealedVideo> uploadSealedVideo(
    File file,
    String peerId, {
    void Function(double progress)? onProgress,
  }) async {
    final me = client.auth.currentUser?.id;
    if (me == null) throw const AuthException('Sign in to send videos.');
    final size = await file.length();
    if (size > maxVideoBytes) {
      throw StateError('Video is larger than 64 MB.');
    }
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final base = file.uri.pathSegments.last;
    Future<SealedUpload> putBytes(
      Uint8List bytes,
      String name,
      double weight,
    ) async {
      final sealed = await MediaSeal.seal(bytes);
      final path = '$me/$peerId/$stamp-$name.enc';
      onProgress?.call(0.1); // Sealing done
      await client.storage
          .from(bucket)
          .uploadBinary(
            path,
            sealed.cipher,
            fileOptions: const FileOptions(upsert: true),
          );
      onProgress?.call(weight); // Upload done (weight = progress fraction)
      return SealedUpload(
        path: path,
        key: base64Encode(sealed.key),
        nonce: base64Encode(sealed.nonce),
      );
    }

    final videoBytes = await file.readAsBytes();
    final video = await putBytes(videoBytes, base, 0.7);

    // Thumbnail extraction removed: video_thumbnail plugin is unmaintained and
    // breaks Android build (jcenter/AGP9). The bubble renders a duration tile
    // until a maintained thumbnail solution lands.
    onProgress?.call(1.0);
    return SealedVideo(
      path: video.path,
      key: video.key,
      nonce: video.nonce,
      thumbPath: '',
      thumbKey: '',
      thumbNonce: '',
    );
  }

  Future<XFile?> pickGalleryVideo() {
    AppLock.suppressRelockOnce = true;
    return ImagePicker().pickVideo(
      source: ImageSource.gallery,
      maxDuration: const Duration(minutes: 3),
    );
  }

  Future<XFile?> pickCameraVideo({
    Duration maxDuration = const Duration(minutes: 3),
  }) {
    AppLock.suppressRelockOnce = true;
    return ImagePicker().pickVideo(
      source: ImageSource.camera,
      maxDuration: maxDuration,
    );
  }

  Future<XFile?> pickGalleryImage() {
    AppLock.suppressRelockOnce = true;
    return ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: _imageWidth,
      imageQuality: _imageQuality,
    );
  }

  /// Image-only multi-selection with the same HD/low-data sizing.
  Future<List<XFile>> pickGalleryImages() async {
    AppLock.suppressRelockOnce = true;
    return ImagePicker().pickMultiImage(
      imageQuality: _imageQuality,
      maxWidth: _imageWidth,
    );
  }

  Future<XFile?> pickCameraImage() {
    AppLock.suppressRelockOnce = true;
    return ImagePicker().pickImage(
      source: ImageSource.camera,
      maxWidth: _imageWidth,
      imageQuality: _imageQuality,
    );
  }

  double get _imageWidth {
    final prefs = preferences;
    if (prefs == null) return 1600;
    final options = ChatPreferences(prefs);
    if (options.lowDataMode) return 1280;
    return options.hdMedia ? 2048 : 1600;
  }

  int get _imageQuality {
    final prefs = preferences;
    if (prefs == null) return 85;
    final options = ChatPreferences(prefs);
    if (options.lowDataMode) return 70;
    return options.hdMedia ? 100 : 85;
  }
}
