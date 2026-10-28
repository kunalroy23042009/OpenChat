import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Content-free error reporting for pilot operations.
///
/// Reports carry stable codes, the failing area, and small allowlisted
/// context — never message bodies, ciphertext, keys, fingerprints, or raw
/// native exception strings (which may describe key material handling).
/// The sink is the local log plus, when a backend is signed in, the
/// allowlist-capped `client_events` table for pilot forensics.
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

  // ---- Structured area reporting + cloud observability sink -------------

  /// Client for the `client_events` cloud table, set once the backend is
  /// signed in (cleared on sign-out). Null => local-log only.
  static SupabaseClient? _client;

  /// Call after Supabase is initialized / when auth state changes.
  static void attachClient(SupabaseClient? client) => _client = client;

  /// Per-area session caps so a failing loop cannot flood the log or the
  /// backend table.
  static final Map<String, int> _areaQuota = {};
  static const _areaQuotaLimit = 12;

  /// Queue of pending cloud reports; flushed opportunistically.
  static final List<Map<String, dynamic>> _pendingEvents = [];
  static Completer<void>? _flushInFlight;

  /// Reports a failure within a named area. The optional [code] is a
  /// stable discriminator (e.g. `pool_low`, `claim_empty`); [details]
  /// accept only short scrubbed strings/ints/bools — never content.
  static void report({
    required String area,
    String code = 'failure',
    Object? error,
    Map<String, String>? details,
  }) {
    final used = (_areaQuota[area] ?? 0) + 1;
    _areaQuota[area] = used;
    final capped = used > _areaQuotaLimit;
    final event = <String, dynamic>{
      'area': area,
      'code': capped ? 'quota_capped' : code,
      'details': <String, dynamic>{
        for (final e in details?.entries ?? const <MapEntry<String, String>>[])
          if (_scrubValue(e.value) != null) e.key: _scrubValue(e.value),
      },
    };
    if (error != null) {
      final built = build(area: area, error: error);
      final kind = built['code']?.toString() ?? 'unexpected';
      event['details']['kind'] =
          kind.length > 32 ? kind.substring(0, 32) : kind;
    }
    debugPrint('error-report $event');
    if (!capped) {
      _pendingEvents.add(event);
      _scheduleFlush();
    }
  }

  /// Convenience wrapper matching call sites that already hold an error.
  static void reportError(
    String area,
    Object error, {
    String code = 'failure',
    Map<String, String>? details,
  }) =>
      report(area: area, code: code, error: error, details: details);

  static void _scheduleFlush() {
    if (_flushInFlight != null) return;
    final client = _client;
    if (client == null || client.auth.currentUser?.id == null) {
      // Keep at most one tick of events; drop the rest.
      if (_pendingEvents.length > 40) _pendingEvents.removeRange(0, 20);
      return;
    }
    final completer = Completer<void>();
    _flushInFlight = completer;
    unawaited(
      Future<void>(() async {
        try {
          // Small settle window so one action can batch its follow-ups.
          await Future<void>.delayed(const Duration(milliseconds: 250));
          final batch = List.of(_pendingEvents);
          _pendingEvents.clear();
          if (batch.isEmpty) return;
          await client.rpc(
            'report_client_event',
            params: {'p_events': batch.take(20).toList()},
          );
        } catch (_) {
          // Observability must never throw into app flows.
        } finally {
          _flushInFlight = null;
          if (_pendingEvents.isNotEmpty) _scheduleFlush();
        }
      }),
    );
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
