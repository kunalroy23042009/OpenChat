import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Pending encrypted activity only: never fetches/decrypts message bodies.
/// Counts include transport controls; callers should display an unread dot,
/// rather than claiming an exact unread-message count.
class DirectUnread extends ChangeNotifier {
  DirectUnread(this.client);
  final SupabaseClient client;
  Map<String, int> _counts = {};
  Map<String, int> get counts => Map.unmodifiable(_counts);
  RealtimeChannel? _channel;
  Timer? _poll;
  Timer? _debounce;
  Future<void>? _refresh;
  bool _disposed = false;
  String? _account;

  void start() {
    final account = client.auth.currentUser?.id;
    if (account == null || _account == account || _disposed) return;
    _account = account;
    _channel = client.channel('direct-unread:$account')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'envelope_receipts',
        callback: (_) {
          _debounce?.cancel();
          _debounce = Timer(const Duration(milliseconds: 250), refresh);
        },
      )
      ..subscribe();
    _poll = Timer.periodic(const Duration(seconds: 20), (_) => refresh());
    unawaited(refresh());
  }

  Future<void> refresh() =>
      _refresh ??= _load().whenComplete(() => _refresh = null);

  Future<void> _load() async {
    final account = client.auth.currentUser?.id;
    if (_disposed || account == null) return;
    try {
      final result = await client.rpc('direct_unread_counts');
      final counts = <String, int>{};
      if (result is Map) {
        for (final entry in result.entries) {
          final v = entry.value;
          if (v is int) counts[entry.key] = v;
        }
      }
      if (_disposed || client.auth.currentUser?.id != account) return;
      if (!mapEquals(_counts, counts)) {
        _counts = counts;
        notifyListeners();
      }
    } catch (_) {
      // Keep the last successful snapshot offline; the next poll retries.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _debounce?.cancel();
    final channel = _channel;
    if (channel != null) unawaited(client.removeChannel(channel));
    super.dispose();
  }
}
