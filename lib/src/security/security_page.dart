import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'device_security.dart';

class SecurityPage extends StatefulWidget {
  const SecurityPage({super.key, this.accountId});
  final String? accountId;
  @override
  State<SecurityPage> createState() => _SecurityPageState();
}

class _SecurityPageState extends State<SecurityPage> {
  final security = DeviceSecurity();
  DeviceIdentityStatus? identity;
  Map<String, bool>? checks;
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    if (security.supported && widget.accountId != null) {
      operation(() async {
        final status = await security.status(widget.accountId!);
        if (mounted) setState(() => identity = status);
      });
    }
  }

  Future<void> operation(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } on PlatformException catch (e) {
      if (mounted) {
        setState(
          () =>
              error = e.message ?? 'The security operation failed. Try again.',
        );
      }
    } on MissingPluginException {
      if (mounted) {
        setState(
          () => error = 'The native security bridge is missing. Install the latest Android build.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              error = 'Security check failed. Existing keys were not replaced.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Device security')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Icon(
              Icons.phonelink_lock_rounded,
              size: 56,
              color: Color(0xFF245CDB),
            ),
            const SizedBox(height: 20),
            const Text(
              'Keys that stay\non your phone.',
              style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w800,
                height: 1.15,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Phase 3 · Android encryption foundation',
              style: TextStyle(color: Color(0xFF66748A)),
            ),
            const SizedBox(height: 20),
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'This prepares a local Signal identity and checks the native encryption library. Chat messages are still a local, unencrypted demo. Network messaging is not enabled.',
                ),
              ),
            ),
            const SizedBox(height: 20),
            if (!security.supported)
              const Text(
                'Native encryption is currently available on Android only. iOS and web integration are pending.',
              )
            else ...[
              if (busy) const LinearProgressIndicator(),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              const Text(
                'Your device identity',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              if (widget.accountId == null)
                const Text(
                  'Sign in to create a separate identity for your account. You can run the local library checks below without signing in.',
                )
              else if (identity?.initialized == true) ...[
                const ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.check_circle_outline),
                  title: Text('Local identity created'),
                  subtitle: Text(
                    'Private key encrypted with an Android Keystore key.',
                  ),
                ),
                Text(
                  identity!.hardwareBacked ? 'Wrapping key: hardware-backed' : 'Wrapping key: Android Keystore (hardware backing not reported)',
                ),
                const SizedBox(height: 16),
                const Text(
                  'Local public-key fingerprint',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                SelectableText(
                  identity!.fingerprint ?? '',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                ),
                const SizedBox(height: 8),
                const Text(
                  'This identifies your local key. It is not a contact safety number or proof that a conversation is verified.',
                  style: TextStyle(fontSize: 12),
                ),
              ] else ...[
                const Text(
                  'Create a persistent identity for this account on this phone. No private key is uploaded. Uninstalling or clearing app data loses this identity.',
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: busy
                      ? null
                      : () => operation(() async {
                          final status = await security.initialize(
                            widget.accountId!,
                          );
                          if (mounted) setState(() => identity = status);
                        }),
                  icon: const Icon(Icons.key),
                  label: const Text('Create device identity'),
                ),
              ],
              const Divider(height: 40),
              const Text(
                'Test the encryption library',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              const Text(
                'Two temporary identities exchange test messages entirely on this phone. They do not use your account identity or contact anyone.',
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: busy
                    ? null
                    : () => operation(() async {
                        setState(() => checks = null);
                        final result = await security.selfTest();
                        if (mounted) setState(() => checks = result);
                      }),
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('Run encryption checks'),
              ),
              if (checks != null) ...[
                const SizedBox(height: 12),
                for (final entry in const {
                  'roundTrip': 'Encrypt and decrypt in both directions',
                  'oneTimePreKeyConsumed': 'Consume the one-time prekey',
                  'outOfOrder': 'Decrypt out-of-order messages',
                  'replayRejected': 'Reject a replayed message',
                  'tamperRejected': 'Reject a modified message',
                  'identityChangeRejected':
                      'Reject an unexpected identity change',
                }.entries)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      checks![entry.key] == true
                          ? Icons.check_circle_outline
                          : Icons.error_outline,
                      color: checks![entry.key] == true
                          ? const Color(0xFF23765B)
                          : Theme.of(context).colorScheme.error,
                    ),
                    title: Text(entry.value),
                    subtitle: Text(
                      checks![entry.key] == true ? 'Passed' : 'Failed',
                    ),
                  ),
              ],
              const SizedBox(height: 24),
              const Text(
                'Powered by libsignal 0.105.0 · AGPLv3\nNative Signal keys are never returned to Flutter. Encrypted message storage and persistent sessions are still pending.',
                style: TextStyle(fontSize: 12, color: Color(0xFF66748A)),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
