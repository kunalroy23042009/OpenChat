import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'call_screen.dart';
import 'call_repository.dart';

class CallLogItem {
  const CallLogItem({
    required this.id,
    required this.contactName,
    required this.username,
    required this.timestamp,
    required this.type,
    required this.isIncoming,
    required this.isMissed,
  });

  final String id;
  final String contactName;
  final String username;
  final DateTime timestamp;
  final CallType type;
  final bool isIncoming;
  final bool isMissed;
}

class CallHistoryPage extends StatefulWidget {
  const CallHistoryPage({super.key, this.client});

  final SupabaseClient? client;

  @override
  State<CallHistoryPage> createState() => _CallHistoryPageState();
}

class _CallHistoryPageState extends State<CallHistoryPage> {
  /// Real call entries only: cloud history when signed in, plus calls
  /// placed on this device. No fictional sample entries.
  final List<CallLogItem> _logs = [];

  @override
  void initState() {
    super.initState();
    _loadCloudLogs();
  }

  Future<void> _loadCloudLogs() async {
    final client = widget.client;
    if (client?.auth.currentUser == null) return;
    try {
      final cloud = await CallRepository(client!).list();
      if (!mounted) return;
      setState(() {
        _logs
          ..clear()
          ..addAll(
            cloud.map(
              (log) => CallLogItem(
                id: log.id,
                contactName: log.peerLabel,
                username: log.peerLabel,
                timestamp: log.startedAt,
                type: log.callType == 'video' ? CallType.video : CallType.voice,
                isIncoming: log.direction == 'incoming',
                isMissed: log.outcome == 'missed',
              ),
            ),
          );
      });
    } catch (_) {
      // Keep demo logs available when offline or before migration deployment.
    }
  }

  void _startCall(CallLogItem item, CallType type) {
    final startedAt = DateTime.now();
    final session = ActiveCallSession(
      callId: DateTime.now().millisecondsSinceEpoch.toString(),
      peerUsername: item.username,
      peerDisplayName: item.contactName,
      type: type,
    );

    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => CallScreen(
          session: session,
          onEndCall: () async {
            Navigator.pop(context);
            final client = widget.client;
            if (client?.auth.currentUser != null) {
              try {
                await CallRepository(client!).add(
                  peerLabel: item.contactName,
                  callType: type == CallType.video ? 'video' : 'voice',
                  outcome: session.durationSeconds > 0 ? 'completed' : 'failed',
                  startedAt: startedAt,
                  durationSeconds: session.durationSeconds,
                );
                await _loadCloudLogs();
              } catch (_) {}
            }
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Calls'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_call),
            onPressed: () {
              if (_logs.isNotEmpty) {
                _startCall(_logs.first, CallType.voice);
              }
            },
          ),
        ],
      ),
      body: ListView(
        children: [
          ListTile(
            leading: CircleAvatar(
              backgroundColor: theme.colorScheme.primary.withValues(
                alpha: 0.15,
              ),
              child: Icon(Icons.link, color: theme.colorScheme.primary),
            ),
            title: const Text(
              'Create call link',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: const Text('Share a link for your OpenChat call'),
            onTap: () {
              final token = DateTime.now().microsecondsSinceEpoch.toRadixString(
                36,
              );
              Clipboard.setData(
                ClipboardData(text: 'https://openchat.app/call/$token'),
              );
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('E2EE call link copied to clipboard'),
                ),
              );
            },
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'Recent calls',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.grey,
                fontSize: 13,
              ),
            ),
          ),
          ..._logs.map(
            (log) => ListTile(
              leading: CircleAvatar(
                backgroundColor: theme.colorScheme.primary,
                child: Text(
                  log.contactName[0].toUpperCase(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              title: Text(
                log.contactName,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: log.isMissed ? Colors.red : null,
                ),
              ),
              subtitle: Row(
                children: [
                  Icon(
                    log.isIncoming ? Icons.call_received : Icons.call_made,
                    size: 14,
                    color: log.isMissed
                        ? Colors.red
                        : (log.isIncoming ? Colors.green : Colors.blue),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Today, ${_formatTime(log.timestamp)}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.call),
                    color: theme.colorScheme.primary,
                    onPressed: () => _startCall(log, CallType.voice),
                  ),
                  IconButton(
                    icon: const Icon(Icons.videocam),
                    color: theme.colorScheme.primary,
                    onPressed: () => _startCall(log, CallType.video),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'add_call_fab',
        backgroundColor: const Color(0xFF00A884),
        foregroundColor: Colors.white,
        tooltip: 'Start new call',
        onPressed: () {
          if (_logs.isNotEmpty) {
            _startCall(_logs.first, CallType.voice);
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Select a contact to call')),
            );
          }
        },
        child: const Icon(Icons.add_call),
      ),
    );
  }

  String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}
