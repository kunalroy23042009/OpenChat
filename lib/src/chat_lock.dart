import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// App-level chat lock. The PIN lives in platform secure storage
/// (Android Keystore / iOS Keychain), never in plain preferences.
class ChatLock {
  static const _pinKey = 'openchat.lock_pin';
  static const _storage = FlutterSecureStorage();

  static Future<bool> hasPin() async =>
      (await _storage.read(key: _pinKey))?.isNotEmpty == true;

  static Future<bool> verifyPin(String pin) async =>
      (await _storage.read(key: _pinKey)) == pin && pin.isNotEmpty;

  static Future<void> setPin(String pin) =>
      _storage.write(key: _pinKey, value: pin);

  static bool validPin(String pin) =>
      RegExp(r'^[0-9]{4}$').hasMatch(pin);

  /// Prompts for the existing PIN. Returns true when it matches.
  static Future<bool> promptVerify(BuildContext context) async {
    final controller = TextEditingController();
    String? error;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: const Text('Locked chats'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Enter your 4-digit chat lock PIN.'),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                obscureText: true,
                maxLength: 4,
                decoration: InputDecoration(
                  hintText: '••••',
                  counterText: '',
                  errorText: error,
                ),
                onSubmitted: (_) async {
                  if (await verifyPin(controller.text.trim())) {
                    if (ctx.mounted) Navigator.pop(ctx, true);
                  } else {
                    setDialog(() => error = 'Wrong PIN. Try again.');
                  }
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                if (await verifyPin(controller.text.trim())) {
                  if (ctx.mounted) Navigator.pop(ctx, true);
                } else {
                  setDialog(() => error = 'Wrong PIN. Try again.');
                }
              },
              child: const Text('Unlock'),
            ),
          ],
        ),
      ),
    );
    return ok == true;
  }

  /// Sets or changes the PIN (enter + confirm). Returns true when saved.
  static Future<bool> promptSetup(BuildContext context) async {
    if (await hasPin()) {
      if (!context.mounted || !await promptVerify(context)) return false;
    }
    if (!context.mounted) return false;
    final first = TextEditingController();
    final second = TextEditingController();
    String? error;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: const Text('Chat lock PIN'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Choose a 4-digit PIN for locked chats.'),
              const SizedBox(height: 12),
              TextField(
                controller: first,
                keyboardType: TextInputType.number,
                obscureText: true,
                maxLength: 4,
                decoration: const InputDecoration(
                  hintText: 'New PIN',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: second,
                keyboardType: TextInputType.number,
                obscureText: true,
                maxLength: 4,
                decoration: InputDecoration(
                  hintText: 'Confirm PIN',
                  counterText: '',
                  errorText: error,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final a = first.text.trim();
                final b = second.text.trim();
                if (!validPin(a)) {
                  setDialog(() => error = 'PIN must be 4 digits.');
                  return;
                }
                if (a != b) {
                  setDialog(() => error = 'PINs do not match.');
                  return;
                }
                await setPin(a);
                if (ctx.mounted) Navigator.pop(ctx, true);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    return ok == true;
  }
}
