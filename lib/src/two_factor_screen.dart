import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'qr_code.dart';

class TwoFactorScreen extends StatefulWidget {
  const TwoFactorScreen({super.key, required this.client});
  final SupabaseClient client;

  @override
  State<TwoFactorScreen> createState() => _TwoFactorScreenState();
}

class _TwoFactorScreenState extends State<TwoFactorScreen> {
  bool _enabled = false;
  bool _loading = true;
  String? _secret;
  List<String> _recoveryCodes = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final userId = widget.client.auth.currentUser?.id;
      if (userId == null) return;
      final resp = await widget.client
          .from('user_preferences')
          .select('totp_enabled, totp_secret, recovery_codes')
          .eq('user_id', userId)
          .maybeSingle();
      if (!mounted) return;
      if (resp != null) {
        setState(() {
          _enabled = resp['totp_enabled'] ?? false;
          _secret = resp['totp_secret'];
          _recoveryCodes = (resp['recovery_codes'] as List<dynamic>?)
                  ?.cast<String>() ??
              const [];
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load 2FA status');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _enable() async {
    if (_secret != null) return;
    setState(() => _loading = true);
    try {
      final resp = await widget.client.functions.invoke('totp-setup');
      if (resp.data is Map) {
        final data = Map<String, dynamic>.from(resp.data as Map);
        final secret = data['secret'] as String?;
        final codes = (data['recovery_codes'] as List<dynamic>?)?.cast<String>() ?? const [];
        if (secret != null && codes.isNotEmpty) {
          if (!mounted) return;
          setState(() {
            _secret = secret;
            _recoveryCodes = codes;
          });
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Failed to start 2FA setup');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _disable(String code) async {
    setState(() => _loading = true);
    try {
      await widget.client.rpc('disable_totp', params: {'p_code': code});
      if (!mounted) return;
      setState(() {
        _enabled = false;
        _secret = null;
        _recoveryCodes = const [];
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Two-factor authentication disabled')),
      );
    } catch (e) {
      if (mounted) setState(() => _error = 'Invalid code');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _useRecoveryCode(String code) async {
    setState(() => _loading = true);
    try {
      await widget.client.rpc('use_recovery_code', params: {'p_code': code});
      if (!mounted) return;
      setState(() {
        _enabled = false;
        _secret = null;
        _recoveryCodes = const [];
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Recovery code accepted, 2FA disabled')),
      );
    } catch (e) {
      if (mounted) setState(() => _error = 'Invalid recovery code');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _confirmSetup(String code) async {
    setState(() => _loading = true);
    try {
      // The server verifies the code against the secret BEFORE storing it,
      // so a mistyped key can never lock the account.
      await widget.client.rpc('enable_totp', params: {
        'p_secret': _secret,
        'p_recovery_codes': _recoveryCodes,
        'p_code': code,
      });
      if (!mounted) return;
      setState(() {
        _enabled = true;
        _secret = null;
        _recoveryCodes = const [];
        _error = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Two-factor authentication enabled')),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Invalid code — check your authenticator app');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showVerifyDialog() {
    final ctrl = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Finish enabling 2FA'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Enter 6-digit code from authenticator app',
          ),
          maxLength: 6,
          keyboardType: TextInputType.number,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _confirmSetup(ctrl.text.trim());
            },
            child: const Text('Verify & enable'),
          ),
        ],
      ),
    );
  }

  void _copyCodes() {
    final text = _recoveryCodes.join('\n');
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Recovery codes copied to clipboard')),
    );
  }

  String _formatSecret(String secret) {
    // Add spaces every 4 chars for readability
    final buffer = StringBuffer();
    for (int i = 0; i < secret.length; i++) {
      if (i > 0 && i % 4 == 0) buffer.write(' ');
      buffer.write(secret[i]);
    }
    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Two-factor authentication')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(24),
              children: [
                if (!_enabled) ...[
                  const Text(
                    'Add an extra layer of security to your account.',
                    style: TextStyle(fontSize: 16),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _enable,
                    icon: const Icon(Icons.security),
                    label: const Text('Enable two-factor authentication'),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ],
                ] else ...[
                  const Text(
                    'Two-factor authentication is enabled.',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'You will need a 6-digit code from your authenticator app when signing in on a new device or changing your password.',
                  ),
                  const SizedBox(height: 24),
                  if (_secret != null) ...[
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Setup key (manual entry)', style: TextStyle(fontWeight: FontWeight.w600)),
                            const SizedBox(height: 8),
                            SelectableText(
                              _formatSecret(_secret!),
                              style: const TextStyle(fontFamily: 'monospace', fontSize: 16, letterSpacing: 2),
                            ),
                            const SizedBox(height: 8),
                            TextButton.icon(
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: _secret!));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Setup key copied')),
                                );
                              },
                              icon: const Icon(Icons.copy),
                              label: const Text('Copy key'),
                            ),
                            const SizedBox(height: 16),
                            QrCodeView(
                              data: 'otpauth://totp/OpenChat:${widget.client.auth.currentUser?.email ?? 'user'}?secret=$_secret&issuer=OpenChat&algorithm=SHA1&digits=6&period=30',
                              size: 200,
                            ),
                            const SizedBox(height: 16),
                            FilledButton.icon(
                              onPressed: _showVerifyDialog,
                              icon: const Icon(Icons.verified_outlined),
                              label: const Text('Verify & finish setup'),
                            ),
                            const SizedBox(height: 16),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text('Recovery codes', style: TextStyle(fontWeight: FontWeight.w600)),
                              const Spacer(),
                              TextButton.icon(
                                onPressed: _copyCodes,
                                icon: const Icon(Icons.copy, size: 18),
                                label: const Text('Copy all'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Each code can be used once. Store them safely.',
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: _recoveryCodes.map((code) => Chip(
                              label: SelectableText(code, style: const TextStyle(fontFamily: 'monospace')),
                              onDeleted: () {},
                            )).toList(),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            final ctrl = TextEditingController();
                            showDialog<void>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text('Disable 2FA'),
                                content: TextField(
                                  controller: ctrl,
                                  decoration: const InputDecoration(
                                    labelText: 'Enter 6-digit code from authenticator app',
                                  ),
                                  maxLength: 6,
                                  keyboardType: TextInputType.number,
                                ),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                                  FilledButton(
                                    onPressed: () {
                                      Navigator.pop(ctx);
                                      _disable(ctrl.text.trim());
                                    },
                                    child: const Text('Disable'),
                                  ),
                                ],
                              ),
                            );
                          },
                          icon: const Icon(Icons.lock_open),
                          label: const Text('Disable 2FA'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            final ctrl = TextEditingController();
                            showDialog<void>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text('Use recovery code'),
                                content: TextField(
                                  controller: ctrl,
                                  decoration: const InputDecoration(
                                    labelText: 'Enter one of your recovery codes',
                                  ),
                                  textCapitalization: TextCapitalization.characters,
                                ),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                                  FilledButton(
                                    onPressed: () {
                                      Navigator.pop(ctx);
                                      _useRecoveryCode(ctrl.text.trim().toUpperCase());
                                    },
                                    child: const Text('Use code'),
                                  ),
                                ],
                              ),
                            );
                          },
                          icon: const Icon(Icons.vpn_key),
                          label: const Text('Recovery code'),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
    );
  }
}