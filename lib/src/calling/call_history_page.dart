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
    required this.outcome,
    required this.durationSeconds,
    this.peerId,
  });

  final String id;
  final String contactName;
  final String username;
  final DateTime timestamp;
  final CallType type;
  final bool isIncoming;

  /// 'completed', 'declined', 'missed', 'failed' (or '' when unknown).
  final String outcome;
  final int durationSeconds;

  /// Supabase user id when known; without it calls start from chats.
  final String? peerId;

  /// WhatsApp semantics: a call we never answered or that failed.
  bool get isMissed => outcome == 'missed' || outcome == 'failed';
}

class CallHistoryPage extends StatefulWidget {
  const CallHistoryPage({super.key, this.client, this.onNewCall});

  final SupabaseClient? client;

  /// Opens the contact picker (WhatsApp's new-call button). When unset the
  /// buttons fall back to a hint.
  final VoidCallback? onNewCall;

  @override
  State<CallHistoryPage> createState() => _CallHistoryPageState();
}

class _CallHistoryPageState extends State<CallHistoryPage> {
  /// Real call entries only: cloud history when signed in. No fictional
  /// sample entries.
  List<CallLogItem> _logs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadCloudLogs();
  }

  Future<void> _loadCloudLogs() async {
    final client = widget.client;
    if (client?.auth.currentUser == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final cloud = await CallRepository(client!).list();
      if (!mounted) return;
      setState(() {
        _logs = cloud
            .map(
              (log) => CallLogItem(
                id: log.id,
                contactName: log.peerLabel,
                username: log.peerLabel,
                timestamp: log.startedAt,
                type: log.callType == 'video' ? CallType.video : CallType.voice,
                isIncoming: log.direction == 'incoming',
                outcome: log.outcome,
                durationSeconds: log.durationSeconds,
                peerId: log.peerId,
              ),
            )
            .toList();
        _loading = false;
      });
    } catch (_) {
      // Offline or migration pending: show what we have.
      if (mounted) setState(() => _loading = false);
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
    final missedColor = theme.colorScheme.error;
    final answeredColor = const Color(0xFF00A884);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Calls'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_call),
            tooltip: 'New call',
            onPressed: widget.onNewCall,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _logs.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.call_rounded,
                    size: 56,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'No recent calls',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Missed calls will appear here.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _loadCloudLogs,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
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
                        backgroundColor: theme.colorScheme.primaryContainer,
                        foregroundColor:
                            theme.colorScheme.onPrimaryContainer,
                        child: Text(
                          log.contactName.isEmpty
                              ? '?'
                              : log.contactName[0].toUpperCase(),
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      title: Text(
                        log.contactName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: log.isMissed ? missedColor : null,
                        ),
                      ),
                      subtitle: Row(
                        children: [
                          Icon(
                            log.isMissed
                                ? Icons.call_missed
                                : log.isIncoming
                                ? Icons.call_received
                                : Icons.call_made,
                            size: 15,
                            color: log.isMissed
                                ? missedColor
                                : answeredColor,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              _describeCall(log),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: log.isMissed
                                    ? missedColor
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.call),
                            color: answeredColor,
                            tooltip: 'Voice call',
                            onPressed: () => _startCall(log, CallType.voice),
                          ),
                          IconButton(
                            icon: const Icon(Icons.videocam),
                            color: answeredColor,
                            tooltip: 'Video call',
                            onPressed: () => _startCall(log, CallType.video),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'add_call_fab',
        backgroundColor: const Color(0xFF00A884),
        foregroundColor: Colors.white,
        tooltip: 'Start new call',
        onPressed:
            widget.onNewCall ??
            () => ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Select a contact to call')),
            ),
        child: const Icon(Icons.add_call),
      ),
    );
  }

  /// WhatsApp-style subtitle: direction, relative day, time and, for
  /// answered calls, the duration.
  String _describeCall(CallLogItem log) {
    final parts = <String>[];
    parts.add(log.isIncoming ? 'Incoming' : 'Outgoing');
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day);
    final callDay = DateTime(
      log.timestamp.year,
      log.timestamp.month,
      log.timestamp.day,
    );
    final difference = day.difference(callDay).inDays;
    final dayLabel = switch (difference) {
      0 => 'Today',
      1 => 'Yesterday',
      _ when difference < 7 && difference > 1 =>
        _weekday(log.timestamp.weekday),
      _ =>
        '${log.timestamp.day}/${log.timestamp.month}/${log.timestamp.year}',
    };
    final clock =
        '${log.timestamp.hour.toString().padLeft(2, '0')}:'
        '${log.timestamp.minute.toString().padLeft(2, '0')}';
    parts.add('$dayLabel, $clock');
    if (!log.isMissed && log.durationSeconds > 0) {
      final minutes = log.durationSeconds ~/ 60;
      final seconds = (log.durationSeconds % 60).toString().padLeft(2, '0');
      parts.add('$minutes:$seconds');
    } else if (log.isMissed) {
      parts.add(
        log.outcome == 'failed' ? 'Not answered' : 'Missed',
      );
    }
    return parts.join(' · ');
  }

  String _weekday(int weekday) => const {
    1: 'Monday',
    2: 'Tuesday',
    3: 'Wednesday',
    4: 'Thursday',
    5: 'Friday',
    6: 'Saturday',
    7: 'Sunday',
  }[weekday]!;
}
