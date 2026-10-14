// ignore_for_file: deprecated_member_use
// RadioListTile groupValue/onChanged: the suggested RadioGroup ancestor
// does not exist in this Flutter release yet.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../chat_store.dart';
import 'chat_backup.dart';

/// WhatsApp-style chat backup: encrypted history in the cloud, automatic
/// schedule, and password restore on any device. Media bytes stay in
/// chat-media and re-download on demand; the backup holds every message,
/// star, pin, draft, and reaction.
class BackupPage extends StatefulWidget {
  const BackupPage({super.key, required this.store, required this.client});
  final ChatStore store;
  final SupabaseClient client;

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  String get _uid => widget.client.auth.currentUser!.id;

  bool _busy = false;
  String? _feedback;
  Future<({DateTime updatedAt, int bytes})?>? _infoFuture;

  @override
  void initState() {
    super.initState();
    _refreshInfo();
  }

  void _refreshInfo() {
    if (!mounted) return;
    setState(() {
      _infoFuture = ChatBackup.backupInfo(widget.client, _uid);
    });
  }

  Future<void> _setFrequency(String value) async {
    await ChatBackup.setFrequency(widget.store.preferences, _uid, value);
    if (mounted) setState(() {});
  }

  String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  Future<String?> _askPassword({
    required String title,
    required String confirmLabel,
    bool confirm = false,
  }) async {
    final first = TextEditingController();
    final second = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: first,
                obscureText: true,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Backup password (min 8 characters)',
                  border: OutlineInputBorder(),
                ),
              ),
              if (confirm) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: second,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Repeat password',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (confirm && first.text != second.text) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(content: Text('Passwords do not match.')),
                  );
                  return;
                }
                Navigator.pop(ctx, first.text);
              },
              child: Text(confirmLabel),
            ),
          ],
        ),
      );
    } finally {
      first.dispose();
      second.dispose();
    }
  }

  Future<void> _backUpNow() async {
    if (_busy) return;
    final password = await _askPassword(
      title: 'Back up chats',
      confirmLabel: 'Back up',
      confirm: true,
    );
    if (password == null || !mounted) return;
    setState(() {
      _busy = true;
      _feedback = null;
    });
    try {
      final result = await ChatBackup.backupNow(
        client: widget.client,
        store: widget.store,
        uid: _uid,
        password: password,
        prefs: widget.store.preferences,
      );
      if (!mounted) return;
      setState(
        () => _feedback =
            'Backed up ${result.messages} messages in ${result.peers} direct chats and ${result.groups} groups (${_size(result.bytes)}).',
      );
      _refreshInfo();
    } catch (e) {
      if (mounted) {
        setState(
          () => _feedback = e is StateError
              ? e.message.toString()
              : 'Backup failed. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    if (_busy) return;
    final password = await _askPassword(
      title: 'Restore backup',
      confirmLabel: 'Restore',
    );
    if (password == null || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore chats?'),
        content: const Text(
          'Cloud messages merge into this device. Nothing already here is deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _feedback = null;
    });
    try {
      final result = await ChatBackup.restoreLatest(
        client: widget.client,
        store: widget.store,
        uid: _uid,
        password: password,
      );
      if (!mounted) return;
      setState(
        () => _feedback =
            'Restored ${result.messages} messages in ${result.peers} direct chats and ${result.groups} group archives.',
      );
    } catch (e) {
      if (mounted) {
        setState(
          () => _feedback = e is StateError
              ? e.message.toString()
              : 'Restore failed. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteBackup() async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete cloud backup?'),
        content: const Text(
          'This removes the encrypted backup from the cloud. Chats on this device stay.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _feedback = null;
    });
    try {
      await ChatBackup.deleteBackup(widget.client, _uid);
      await ChatBackup.forgetKey(_uid);
      await ChatBackup.forgetMediaKey(_uid);
      await ChatBackup.forgetLocalMediaMap(widget.store.preferences, _uid);
      if (!mounted) return;
      setState(() => _feedback = 'Cloud backup deleted.');
      _refreshInfo();
    } catch (_) {
      if (mounted) {
        setState(() => _feedback = 'Delete failed. Check your connection.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final freq = ChatBackup.frequency(widget.store.preferences, _uid);
    final last = ChatBackup.lastBackup(widget.store.preferences, _uid);
    return Scaffold(
      appBar: AppBar(title: const Text('Chat backup')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text(
            'End-to-end encrypted history in the cloud. Only your backup password can open it — not even the server. The three newest successful snapshots are retained for recovery.',
            style: TextStyle(color: Color(0xFF66748A), height: 1.4),
          ),
          const SizedBox(height: 16),
          Card(
            child: ListTile(
              leading: const Icon(Icons.cloud_done_outlined),
              title: const Text('Last backup'),
              subtitle: FutureBuilder<({DateTime updatedAt, int bytes})?>(
                future: _infoFuture,
                builder: (context, snapshot) {
                  final info = snapshot.data;
                  final local = last == null
                      ? 'never on this device'
                      : 'this device: ${last.toLocal().toString().split('.').first}';
                  if (info == null) {
                    return Text(
                      snapshot.connectionState == ConnectionState.waiting
                          ? 'Checking cloud…'
                          : 'No cloud backup yet. ($local)',
                    );
                  }
                  return Text(
                    'Cloud: ${info.updatedAt.toLocal().toString().split('.').first} (${_size(info.bytes)}). $local.',
                  );
                },
              ),
              trailing: IconButton(
                tooltip: 'Refresh',
                onPressed: _busy ? null : _refreshInfo,
                icon: const Icon(Icons.refresh),
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _backUpNow,
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.cloud_upload_outlined),
            label: const Text('Back up now'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : _restore,
            icon: const Icon(Icons.cloud_download_outlined),
            label: const Text('Restore backup'),
          ),
          const SizedBox(height: 24),
          const Text(
            'Automatic backups while using the app',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          const Text(
            'Scheduled backups run when OpenChat starts or returns to the foreground. Android may suspend apps in the background, so connect regularly and check the last-backup time.',
            style: TextStyle(color: Color(0xFF66748A), height: 1.4),
          ),
          Column(
            children: [
              for (final option in ChatBackup.frequencies)
                RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    '${option[0].toUpperCase()}${option.substring(1)}',
                  ),
                  subtitle: option == 'never'
                      ? null
                      : const Text('Needs one manual backup first.'),
                  value: option,
                  groupValue: freq,
                  onChanged: _busy
                      ? null
                      : (value) {
                          if (value == null) return;
                          unawaited(_setFrequency(value));
                        },
                ),
            ],
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _busy ? null : _deleteBackup,
            icon: const Icon(Icons.delete_outline, color: Colors.red),
            label: const Text(
              'Delete cloud backup',
              style: TextStyle(color: Colors.red),
            ),
          ),
          if (_feedback != null) ...[
            const SizedBox(height: 16),
            Text(_feedback!, style: const TextStyle(height: 1.4)),
          ],
        ],
      ),
    );
  }
}
