import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Account presence belongs to the app, not to the lifetime of a chat route.
class AppPresence with WidgetsBindingObserver {
  AppPresence(this.client);

  final SupabaseClient client;
  StreamSubscription<AuthState>? _auth;
  Timer? _heartbeat;
  Future<void> _writes = Future<void>.value();
  bool _started = false;
  bool _foreground = true;

  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _auth = client.auth.onAuthStateChange.listen((_) => _sync());
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  void _sync() {
    _heartbeat?.cancel();
    if (!_started || client.auth.currentUser == null) return;
    _publish(_foreground);
    if (_foreground) {
      _heartbeat = Timer.periodic(
        const Duration(minutes: 2),
        (_) => _publish(true),
      );
    }
  }

  void _publish(bool online) {
    final account = client.auth.currentUser?.id;
    if (account == null) return;
    // Serialize transitions so a slow online request cannot overwrite offline.
    _writes = _writes.then((_) async {
      if (client.auth.currentUser?.id != account) return;
      try {
        await client
            .rpc(
              'update_presence',
              params: {'p_is_online': online, 'p_status_message': null},
            )
            .timeout(const Duration(seconds: 10));
      } catch (_) {
        // A later lifecycle transition/heartbeat retries on reconnection.
      }
    });
  }

  void dispose() {
    if (!_started) return;
    _started = false;
    WidgetsBinding.instance.removeObserver(this);
    _heartbeat?.cancel();
    _auth?.cancel();
    _publish(false);
  }
}
