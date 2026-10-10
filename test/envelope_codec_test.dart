import 'package:flutter_test/flutter_test.dart';
import 'package:open_chat/src/security/envelope_codec.dart';

void main() {
  test('encode prefixes the type with a dot separator', () {
    expect(EnvelopeCodec.encode(3, 'QUJD'), '3.QUJD');
  });

  test('candidates splits current rows into a single candidate', () {
    final result = EnvelopeCodec.candidates('2.eHl6');
    expect(result, hasLength(1));
    expect(result.single.key, 2);
    expect(result.single.value, 'eHl6');
  });

  test('candidates falls back to prekey then whisper for legacy rows', () {
    final result = EnvelopeCodec.candidates('QUJD');
    expect(result.map((e) => e.key).toList(), [3, 2]);
    expect(result.every((e) => e.value == 'QUJD'), isTrue);
  });

  test('candidates ignores a non-numeric prefix', () {
    final result = EnvelopeCodec.candidates('x.QUJD');
    expect(result.map((e) => e.key).toList(), [3, 2]);
  });
}
