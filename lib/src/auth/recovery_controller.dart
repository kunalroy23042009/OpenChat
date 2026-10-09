import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Tracks actual recovery events independently of the currently open screen.
class RecoveryController extends ChangeNotifier {
  RecoveryController(Stream<AuthState> events) {
    subscription = events.listen(
      (state) {
        if (state.event == AuthChangeEvent.passwordRecovery &&
            state.session != null) {
          accountId = state.session!.user.id;
          notifyListeners();
        } else if (state.event == AuthChangeEvent.signedOut) {
          accountId = null;
          notifyListeners();
        }
      },
      onError: (Object _) {
        // A failed callback must never be interpreted as a recovery session.
        accountId = null;
        notifyListeners();
      },
    );
  }
  late final StreamSubscription<AuthState> subscription;
  String? accountId;
  void consume() {
    accountId = null;
  }

  @override
  void dispose() {
    subscription.cancel();
    super.dispose();
  }
}
