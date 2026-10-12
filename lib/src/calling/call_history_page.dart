import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'call_flow.dart';
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
    this.peerId,
  });

  final String id;
  final String contactName;
  final String username;
  final DateTime timestamp;
  final CallType type;
  final bool isIncoming;
  final bool isMissed;

  /// Supabase user id when known; without it calls start from chats.
  final String? peerId;
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
                peerId: log.peerId,
              ),
            ));
      });
    } catch (_) {
      // Keep demo logs available when offline or before migration deployment.
    }
  }

  /// Starts a real call when we know the peer's user id; otherwise points
  /// at the encrypted chat, which always can.
  void _startCall(CallLogItem item, CallType type) {
    final client = widget.client;
    if (client?.auth.currentUser == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sign in to place calls.')),
      );
      return;
    }
    final peerId = item.peerId;
    if (peerId == null || peerId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Open their encrypted chat to call this contact.'),
        ),
      );
      return;
    }
    startOutgoingCall(
      context,
      client: client!,
      peerId: peerId,
      peerName: item.contactName,
      type: type,
    ).then((_) {
      if (mounted) _loadCloudLogs();
    });
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
