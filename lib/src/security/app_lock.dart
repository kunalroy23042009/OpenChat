import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

import 'secure_display.dart';

class AppLock {
  static const _storage = FlutterSecureStorage();
  static const _key = 'openchat.appLock.v1';
  static const _timeoutKey = 'openchat.appLock.timeoutSec.v1';
  // Widget tests have no secure-storage plugin; bypass the async gate.
  static bool testBypass = false;
  static final enabled = ValueNotifier(false);
  // WhatsApp-style relock delay. 0 = immediately.
  static final timeout = ValueNotifier<Duration>(Duration.zero);
  static const timeoutOptions = [
    Duration.zero,
    Duration(minutes: 1),
    Duration(minutes: 30),
  ];
  static final auth = LocalAuthentication();
  static Future<void> load() async {
    try {
      // Widget tests have no secure-storage plugin; never hang the gate.
      final value = await _storage
          .read(key: _key)
          .timeout(const Duration(seconds: 2), onTimeout: () => null);
      enabled.value = value == 'true';
      final secs = int.tryParse(
        await _storage
                .read(key: _timeoutKey)
                .timeout(const Duration(seconds: 2), onTimeout: () => null) ??
            '',
      );
      timeout.value = timeoutOptions.contains(Duration(seconds: secs ?? 0))
          ? Duration(seconds: secs ?? 0)
          : Duration.zero;
    } catch (_) {
      /* Unsupported platform tests have no secure storage. */
    }
  }

  static String timeoutLabel(Duration d) {
    if (d == Duration.zero) return 'Immediately';
    if (d == const Duration(minutes: 1)) return 'After 1 minute';
    return 'After 30 minutes';
  }

  static Future<void> setTimeout(Duration value) async {
    if (!timeoutOptions.contains(value)) return;
    await _storage.write(key: _timeoutKey, value: value.inSeconds.toString());
    timeout.value = value;
  }

  static Future<bool> authenticate() async {
    try {
      // biometricOnly:false allows device PIN/pattern/password fallback.
      return await auth.authenticate(
        localizedReason: 'Unlock OpenChat',
        biometricOnly: false,
        persistAcrossBackgrounding: true,
      );
    } catch (e) {
      debugPrint('AppLock authenticate error: $e');
      return false;
    }
  }

  static Future<bool> setEnabled(bool value) async {
    if (value) {
      if (!await auth.isDeviceSupported()) return false;
      if (!await authenticate()) return false;
    }
    await _storage.write(key: _key, value: value.toString());
    enabled.value = value;
    return true;
  }

  /// Emergency reset when biometrics/device PIN are broken.
  /// Prevents reinstall lockout: clears the flag without requiring auth.
  static Future<void> clear() async {
    try {
      await _storage.delete(key: _key);
    } catch (_) {}
    enabled.value = false;
  }

  /// Set before launching an external activity (gallery, camera, file
  /// picker, contact picker) so the resume right after does not relock.
  /// Consumed once on the next resume.
  static bool suppressRelockOnce = false;
}

/// Wraps the entire Navigator, including notification/deep-link routes.
/// Native device PIN is a fallback when biometrics are unavailable.
class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key, required this.child});
  final Widget child;
  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  bool _loading = true,
      _locked = true,
      _authenticating = false,
      _protected = false;
  DateTime? _backgroundedAt;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppLock.enabled.addListener(_changed);
    _initialize();
  }

  Future<void> _initialize() async {
    if (AppLock.testBypass) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _locked = false;
      });
      return;
    }
    await AppLock.load();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _locked = AppLock.enabled.value;
    });
    await _protection();
  }

  Future<void> _protection() async {
    if (AppLock.enabled.value && !_protected) {
      try {
        await SecureDisplay.acquire();
        if (!mounted) {
          await SecureDisplay.release();
          return;
        }
        _protected = true;
      } catch (_) {}
    } else if (!AppLock.enabled.value && _protected) {
      _protected = false;
      await SecureDisplay.release();
    }
  }

  void _changed() {
    if (!mounted) return;
    setState(() => _locked = AppLock.enabled.value);
    unawaited(_protection());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!AppLock.enabled.value || _authenticating || !mounted) return;
    if (state == AppLifecycleState.resumed) {
      // External pickers (gallery/camera/files) pause the activity and
      // resume right after: never relock for that single resume.
      if (AppLock.suppressRelockOnce) {
        AppLock.suppressRelockOnce = false;
        _backgroundedAt = null;
        return;
      }
      if (_locked) {
        _backgroundedAt = null;
        return;
      }
      final left = _backgroundedAt;
      _backgroundedAt = null;
      // Immediately = lock on any real backgrounding. Otherwise lock only
      // once the chosen grace period has elapsed. `inactive` (dialogs,
      // permission sheets, calls) never arms the lock by itself.
      if (left != null &&
          (AppLock.timeout.value == Duration.zero ||
              DateTime.now().difference(left) >= AppLock.timeout.value)) {
        setState(() => _locked = true);
      }
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      // Record only. Locking happens on resume, so a transient pause
      // (auth prompt, picker, call UI) can never trap the user on the
      // lock screen while they are still inside the app flow.
      _backgroundedAt ??= DateTime.now();
    }
  }

  Future<void> _unlock() async {
    if (_authenticating) return;
    setState(() => _authenticating = true);
    final granted = await AppLock.authenticate();
    if (granted) {
      _backgroundedAt = null;
    } else if (mounted) {
      // Show error if authentication failed
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Authentication failed. Try again.')),
      );
    }
    if (mounted)
      setState(() {
        _authenticating = false;
        _locked = !granted;
      });
  }

  @override
  void dispose() {
    AppLock.enabled.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    if (_protected) unawaited(SecureDisplay.release());
    super.dispose();
  }

  Future<void> _resetLock() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset app lock?'),
        content: const Text(
          'This turns off App lock on this device without biometrics. Your chats are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await AppLock.clear();
      _backgroundedAt = null;
      if (mounted) setState(() => _locked = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cover = _loading || (AppLock.enabled.value && _locked);
    return Stack(
      children: [
        Offstage(
          offstage: cover,
          child: TickerMode(enabled: !cover, child: widget.child),
        ),
        if (cover)
          Positioned.fill(
            child: Material(
              color: Theme.of(context).colorScheme.surface,
              child: Center(
                child: _loading
                    ? const CircularProgressIndicator()
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.lock_outline, size: 48),
                          const SizedBox(height: 16),
                          const Text('OpenChat is locked'),
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            onPressed: _authenticating ? null : _unlock,
                            icon: const Icon(Icons.fingerprint),
                            label: const Text('Unlock'),
                          ),
                          TextButton(
                            onPressed: _authenticating ? null : _resetLock,
                            child: const Text('Forgot? Reset lock'),
                          ),
                        ],
                      ),
              ),
            ),
          ),
      ],
    );
  }
}
