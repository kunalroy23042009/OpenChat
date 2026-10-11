import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_chat/src/media/media_seal.dart';

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void main() {
  test('seal round-trips bytes with fresh key material', () {
    final plain = Uint8List.fromList(utf8.encode('fake-image-bytes-12345'));
    final a = MediaSeal.seal(plain);
    final b = MediaSeal.seal(plain);
    expect(a.key.length, 32);
    expect(a.nonce.length, 12);
    // Fresh randomness: same input seals differently.
    expect(_eq(a.cipher, b.cipher), isFalse);
    expect(_eq(a.key, b.key), isFalse);
    expect(
      _eq(MediaSeal.open(cipher: a.cipher, key: a.key, nonce: a.nonce), plain),
      isTrue,
    );
  });

  test('ciphertext reveals nothing about plaintext', () {
    final plain = Uint8List.fromList(List<int>.filled(64, 7));
    final sealed = MediaSeal.seal(plain);
    expect(sealed.cipher.length, greaterThanOrEqualTo(plain.length));
    expect(_eq(sealed.cipher, plain), isFalse);
  });

  test('wrong key fails authentication instead of garbage', () {
    final sealed = MediaSeal.seal(Uint8List.fromList([1, 2, 3, 4]));
    final wrongKey = Uint8List.fromList(List<int>.filled(32, 9));
    expect(
      () => MediaSeal.open(
        cipher: sealed.cipher,
        key: wrongKey,
        nonce: sealed.nonce,
      ),
      throwsA(anything),
    );
  });

  test('tampered bytes fail authentication', () {
    final sealed = MediaSeal.seal(Uint8List.fromList([5, 6, 7, 8]));
    final tampered = Uint8List.fromList(sealed.cipher)..[0] ^= 0xFF;
    expect(
      () => MediaSeal.open(
        cipher: tampered,
        key: sealed.key,
        nonce: sealed.nonce,
      ),
      throwsA(anything),
    );
  });
}
