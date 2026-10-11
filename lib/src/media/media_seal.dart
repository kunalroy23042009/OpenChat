import 'dart:math';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as enc;

/// Per-file AES-256-GCM sealing for chat media. Each file gets a fresh
/// random key and nonce; both travel inside the Signal-encrypted message,
/// so the storage server only ever sees ciphertext. Pure Dart, no plugins.
class MediaSeal {
  /// Seals [plain] and returns cipher bytes plus the random key/nonce.
  static ({Uint8List cipher, Uint8List key, Uint8List nonce}) seal(
    Uint8List plain,
  ) {
    final rnd = Random.secure();
    final key = Uint8List.fromList(
      List<int>.generate(32, (_) => rnd.nextInt(256)),
    );
    final nonce = Uint8List.fromList(
      List<int>.generate(12, (_) => rnd.nextInt(256)),
    );
    final encrypter = enc.Encrypter(enc.AES(enc.Key(key), mode: enc.AESMode.gcm));
    final cipher = encrypter.encryptBytes(plain, iv: enc.IV(nonce)).bytes;
    return (
      cipher: Uint8List.fromList(cipher),
      key: key,
      nonce: nonce,
    );
  }

  /// Opens sealed [cipher]. Throws on wrong key/nonce or tampered bytes
  /// (GCM authentication failure).
  static Uint8List open({
    required Uint8List cipher,
    required Uint8List key,
    required Uint8List nonce,
  }) {
    final encrypter = enc.Encrypter(enc.AES(enc.Key(key), mode: enc.AESMode.gcm));
    return Uint8List.fromList(
      encrypter.decryptBytes(enc.Encrypted(cipher), iv: enc.IV(nonce)),
    );
  }
}
