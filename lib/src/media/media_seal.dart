import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Per-file AES-256-GCM sealing for chat media. Each file gets a fresh
/// random key and nonce; both travel inside the Signal-encrypted message,
/// so the storage server only ever sees ciphertext. Pure Dart, no plugins.
class MediaSeal {
  static final AesGcm _aes = AesGcm.with256bits();

  /// Seals [plain] and returns cipher bytes plus the random key/nonce.
  /// Stored layout is ciphertext bytes followed by the 16-byte GCM tag.
  static Future<({Uint8List cipher, Uint8List key, Uint8List nonce})>
  seal(Uint8List plain) async {
    final key = await _aes.newSecretKey();
    final nonce = _aes.newNonce();
    final box = await _aes.encrypt(
      plain,
      secretKey: key,
      nonce: nonce,
    );
    return (
      cipher: Uint8List.fromList([...box.cipherText, ...box.mac.bytes]),
      key: Uint8List.fromList(await key.extractBytes()),
      nonce: Uint8List.fromList(nonce),
    );
  }

  /// Opens sealed [cipher]. Throws on wrong key/nonce or tampered bytes
  /// (GCM authentication failure).
  static Future<Uint8List> open({
    required Uint8List cipher,
    required Uint8List key,
    required Uint8List nonce,
  }) async {
    if (cipher.length < 16) throw StateError('Truncated media.');
    final box = SecretBox(
      cipher.sublist(0, cipher.length - 16),
      nonce: nonce,
      mac: Mac(cipher.sublist(cipher.length - 16)),
    );
    final clear = await _aes.decrypt(
      box,
      secretKey: SecretKey(key),
    );
    return Uint8List.fromList(clear);
  }
}
