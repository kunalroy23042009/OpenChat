import 'package:flutter/material.dart';
import 'call_screen.dart';

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
  const CallHistoryPage({super.key});

  @override
  State<CallHistoryPage> createState() => _CallHistoryPageState();
}

class _CallHistoryPageState extends State<CallHistoryPage> {
  final List<CallLogItem> _logs = [
    CallLogItem(
      id: 'call_1',
      contactName: 'Taylor',
      username: 'taylor',
      timestamp: DateTime.now().subtract(const Duration(minutes: 15)),
      type: CallType.video,
      isIncoming: true,
      isMissed: false,
    ),
    CallLogItem(
      id: 'call_2',
      contactName: 'Alex',
      username: 'alex',
      timestamp: DateTime.now().subtract(const Duration(hours: 3)),
      type: CallType.voice,
      isIncoming: false,
      isMissed: false,
    ),
    CallLogItem(
      id: 'call_3',
      contactName: 'Jordan',
      username: 'jordan',
      timestamp: DateTime.now().subtract(const Duration(days: 1)),
      type: CallType.voice,
      isIncoming: true,
      isMissed: true,
    ),
  ];

  void _startCall(CallLogItem item, CallType type) {
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
          onEndCall: () => Navigator.pop(context),
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
              backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.15),
              child: Icon(Icons.link, color: theme.colorScheme.primary),
            ),
            title: const Text('Create call link', style: TextStyle(fontWeight: FontWeight.bold)),
            subtitle: const Text('Share a link for your Open Chat call'),
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('E2EE call link copied to clipboard')),
              );
            },
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'Recent calls',
              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey, fontSize: 13),
            ),
          ),
          ..._logs.map(
            (log) => ListTile(
              leading: CircleAvatar(
                backgroundColor: theme.colorScheme.primary,
                child: Text(
                  log.contactName[0].toUpperCase(),
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
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
    );
  }

  String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}
