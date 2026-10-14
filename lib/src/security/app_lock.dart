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
  static const timeoutOptions = [Duration.zero, Duration(minutes: 1), Duration(minutes: 30)];
  static final auth = LocalAuthentication();
  static Future<void> load() async {
    try {
      // Widget tests have no secure-storage plugin; never hang the gate.
      final value = await _storage.read(key: _key).timeout(const Duration(seconds: 2), onTimeout: () => null);
      enabled.value = value == 'true';
      final secs = int.tryParse(
        await _storage.read(key: _timeoutKey).timeout(const Duration(seconds: 2), onTimeout: () => null) ?? '');
      timeout.value = timeoutOptions.contains(Duration(seconds: secs ?? 0))
          ? Duration(seconds: secs ?? 0)
          : Duration.zero;
    }
    catch (_) { /* Unsupported platform tests have no secure storage. */ }
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
      return await auth.authenticate(localizedReason: 'Unlock OpenChat', persistAcrossBackgrounding: true);
    } catch (_) { return false; }
  }
  static Future<bool> setEnabled(bool value) async {
    if (!await auth.isDeviceSupported() || !await authenticate()) return false;
    await _storage.write(key: _key, value: value.toString());
    enabled.value = value;
    return true;
  }
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
  bool _loading = true, _locked = true, _authenticating = false, _protected = false;
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
      setState(() { _loading = false; _locked = false; });
      return;
    }
    await AppLock.load();
    if (!mounted) return;
    setState(() { _loading = false; _locked = AppLock.enabled.value; });
    await _protection();
  }
  Future<void> _protection() async {
    if (AppLock.enabled.value && !_protected) {
      try {
        await SecureDisplay.acquire();
        if (!mounted) { await SecureDisplay.release(); return; }
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
      // Relock only once the chosen grace period has elapsed.
      if (_locked) return;
      final left = _backgroundedAt;
      _backgroundedAt = null;
      if (left == null || DateTime.now().difference(left) >= AppLock.timeout.value) {
        setState(() => _locked = true);
      }
      return;
    }
    _backgroundedAt ??= DateTime.now();
    if (AppLock.timeout.value == Duration.zero) {
      setState(() => _locked = true);
    }
  }
  Future<void> _unlock() async {
    if (_authenticating) return;
    setState(() => _authenticating = true);
    final granted = await AppLock.authenticate();
    if (granted) _backgroundedAt = null;
    if (mounted) setState(() { _authenticating = false; _locked = !granted; });
  }
  @override
  void dispose() {
    AppLock.enabled.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    if (_protected) unawaited(SecureDisplay.release());
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    final cover = _loading || (AppLock.enabled.value && _locked);
    return Stack(children: [
      Offstage(offstage: cover, child: TickerMode(enabled: !cover, child: widget.child)),
      if (cover) Positioned.fill(child: Material(color: Theme.of(context).colorScheme.surface,
        child: Center(child: _loading ? const CircularProgressIndicator() : Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.lock_outline, size: 48), const SizedBox(height: 16),
          const Text('OpenChat is locked'), const SizedBox(height: 12),
          FilledButton.icon(onPressed: _authenticating ? null : _unlock, icon: const Icon(Icons.fingerprint), label: const Text('Unlock')),
        ])))),
    ]);
  }
}
