import 'package:flutter/foundation.dart';

/// Content-free error reporting for pilot operations.
///
/// Reports carry stable codes, the failing area, and small allowlisted
/// context — never message bodies, ciphertext, keys, fingerprints, or raw
/// native exception strings (which may describe key material handling).
/// Today the sink is the local log; a network sink lands with device testing.
class ErrorReport {
  /// Short user-safe messages the app itself throws. Anything else collapses
  /// to a stable code so server internals never leave the device.
  static const _safeMessages = {
    'Daily send limit reached. Try again tomorrow.',
    'Contact unavailable. They may have blocked you or removed the connection.',
    'Message rejected by the server.',
    'Key publication failed.',
    'Contact has no published keys yet',
    'Contact unavailable',
    'Contact must reopen the app to refresh one-time keys',
    'Invalid bundle',
    'Invalid payload',
    'Account required',
    'Contact required',
  };

  /// Server raise_exception texts that are safe to forward verbatim.
  static const _safeServerMessages = {
    'Sign in required',
    'Contact unavailable',
    'Contact has no published keys yet',
    'Invalid key bundle',
    'Invalid one-time prekey',
    'Invalid kyber prekey',
    'Invalid attachment size',
    'Uploaded size exceeds reservation',
    'Reservation unavailable',
    'Attachment unavailable',
    'Attachment budget exhausted',
    'Invalid acknowledgment batch',
  };

  /// Builds a report map. [area] names the failing flow
  /// (e.g. `secure-send`, `keys-publish`, `startup`).
  static Map<String, String> build({
    required String area,
    required Object error,
    StackTrace? stack,
    Map<String, String>? context,
  }) {
    final code = _code(error);
    final report = <String, String>{'area': area, 'code': code};
    final detail = _detail(error);
    if (detail != null) report['detail'] = detail;
    if (context != null) {
      for (final entry in context.entries) {
        final value = _scrubValue(entry.value);
        if (value != null) report['ctx_${entry.key}'] = value;
      }
    }
    if (stack != null) report['stack'] = _truncateStack(stack);
    return report;
  }

  static String _code(Object error) {
    final name = error.runtimeType.toString();
    if (name.contains('PostgrestException')) return 'server-rejected';
    if (name.contains('PlatformException')) {
      // Our native bridge only emits SCREAMING_SNAKE codes; forward those.
      try {
        final code = (error as dynamic).code;
        if (code is String && RegExp(r'^[A-Z][A-Z0-9_]{1,31}$').hasMatch(code)) {
          return 'platform-$code';
        }
      } catch (_) {}
      return 'platform-failure';
    }
    if (error is StateError || error is ArgumentError) return 'client-rejected';
    if (error is FormatException) return 'bad-payload';
    return 'unexpected';
  }

  /// Returns a safe detail string, or null when nothing may be forwarded.
  static String? _detail(Object error) {
    final message = _messageOf(error);
    if (message == null) return null;
    if (_safeMessages.contains(message)) return message;
    for (final safe in _safeServerMessages) {
      if (message.contains(safe)) return safe;
    }
    return null;
  }

  static String? _messageOf(Object error) {
    try {
      // Error.message avoids the "Bad state: " toString prefix, so allowlist
      // matching sees the exact text the app threw.
      final message = (error as dynamic).message;
      if (message is String && message.isNotEmpty) return message;
    } catch (_) {}
    try {
      final dynamic e = error;
      final code = e.code;
      if (code is String && code.isNotEmpty) return code;
    } catch (_) {}
    try {
      return error.toString();
    } catch (_) {
      return null;
    }
  }

  /// Drops values that look like secrets or content: long tokens, UUIDs,
  /// base64 blobs, multiline text. Short simple tokens pass through.
  static String? _scrubValue(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.length > 64) return null;
    if (trimmed.contains(RegExp(r'\s'))) return null;
    if (RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(trimmed)) return null;
    if (RegExp(r'^[A-Za-z0-9+/=]{20,}$').hasMatch(trimmed)) return null;
    if (!RegExp(r'^[A-Za-z0-9_@.\-]+$').hasMatch(trimmed)) return null;
    return trimmed;
  }

  static String _truncateStack(StackTrace stack) {
    final lines = stack.toString().split('\n').take(12).join('\n');
    return lines.length > 1200 ? lines.substring(0, 1200) : lines;
  }

  /// Installs global hooks. [sink] receives sanitized reports; defaults to
  /// debug logging. Returns nothing; safe to call once at startup.
  static void install({void Function(Map<String, String>)? sink}) {
    final out = sink ?? ((report) => debugPrint('error-report $report'));
    FlutterError.onError = (details) {
      out(
        build(
          area: 'flutter-framework',
          error: details.exception,
          stack: details.stack,
        ),
      );
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      out(build(area: 'platform', error: error, stack: stack));
      return true;
    };
  }
}
