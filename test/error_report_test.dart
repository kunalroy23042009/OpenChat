import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_chat/src/ops/error_report.dart';

void main() {
  test('safe client messages pass through verbatim', () {
    final report = ErrorReport.build(
      area: 'secure-send',
      error: StateError('Daily send limit reached. Try again tomorrow.'),
    );
    expect(report['code'], 'client-rejected');
    expect(
      report['detail'],
      'Daily send limit reached. Try again tomorrow.',
    );
  });

  test('unknown errors collapse to a code with no detail', () {
    final report = ErrorReport.build(
      area: 'keys-publish',
      error: StateError('Keystore alias missing: openchat.identity.v1.X'),
    );
    expect(report['code'], 'client-rejected');
    expect(report.containsKey('detail'), isFalse);
  });

  test('platform codes stay, platform messages are dropped', () {
    final report = ErrorReport.build(
      area: 'secure-decrypt',
      error: PlatformException(
        code: 'SECURITY_FAILED',
        message: 'javax.crypto.BadPaddingException: tag mismatch',
      ),
    );
    expect(report['code'], 'platform-SECURITY_FAILED');
    expect(report.containsKey('detail'), isFalse);
  });

  test('context scrubs tokens, uuids, blobs, and free text', () {
    final report = ErrorReport.build(
      area: 'secure-receive',
      error: const FormatException('bad envelope'),
      context: {
        'peer': 'not-a-real-peer!!',
        'peerId': '00000000-0000-0000-0000-000000000001',
        'cipher': 'QUJDREVGR0hJSktMTU5PUFFSU1RVVldY',
        'note': 'hello world',
        'stage': 'decrypt',
      },
    );
    expect(report.containsKey('ctx_peer'), isFalse);
    expect(report.containsKey('ctx_peerId'), isFalse);
    expect(report.containsKey('ctx_cipher'), isFalse);
    expect(report.containsKey('ctx_note'), isFalse);
    expect(report['ctx_stage'], 'decrypt');
  });

  test('install routes framework errors to the sink sanitized', () {
    final seen = <Map<String, String>>[];
    ErrorReport.install(sink: seen.add);
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: StateError('Daily send limit reached. Try again tomorrow.'),
      ),
    );
    expect(seen, hasLength(1));
    expect(seen.single['area'], 'flutter-framework');
    expect(seen.single['detail'], contains('Daily send limit'));
  });
}
