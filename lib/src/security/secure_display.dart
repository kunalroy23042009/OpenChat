import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

/// Reference-counted Android capture protection shared by private viewers
/// and the lock screen. A viewer cannot clear a lock screen's secure flag.
class SecureDisplay {
  static const channel = MethodChannel('dev.openchat/privacy');
  static int _users = 0;
  static Future<void> acquire() async {
    if (defaultTargetPlatform != TargetPlatform.android) throw UnsupportedError('Capture protection requires Android.');
    _users++;
    try {
      final ok = await channel.invokeMethod<bool>('setSecure', {'enabled': true});
      if (ok != true) throw StateError('Capture protection unavailable');
    } catch (_) { _users--; rethrow; }
  }
  static Future<void> release() async {
    if (_users <= 0) return;
    _users--;
    if (_users == 0) await channel.invokeMethod('setSecure', {'enabled': false});
  }
}
