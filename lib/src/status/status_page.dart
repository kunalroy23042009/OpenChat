import 'package:flutter/material.dart';

class StatusItem {
  const StatusItem({
    required this.id,
    required this.authorName,
    required this.content,
    required this.timestamp,
    this.isMe = false,
    this.isViewed = false,
    this.backgroundColor = const Color(0xFF245CDB),
  });

  final String id;
  final String authorName;
  final String content;
  final DateTime timestamp;
  final bool isMe;
  final bool isViewed;
  final Color backgroundColor;
}

class StatusPage extends StatefulWidget {
  const StatusPage({super.key});

  @override
  State<StatusPage> createState() => _StatusPageState();
}

class _StatusPageState extends State<StatusPage> {
  final List<StatusItem> _statuses = [
    StatusItem(
      id: 'my_status_1',
      authorName: 'My Status',
      content: 'Available on Open Chat!',
      timestamp: DateTime.now().subtract(const Duration(hours: 2)),
      isMe: true,
      isViewed: true,
    ),
    StatusItem(
      id: 'status_taylor',
      authorName: 'Taylor',
      content: '☕ Coffee first before coding!',
      timestamp: DateTime.now().subtract(const Duration(minutes: 45)),
      isViewed: false,
      backgroundColor: const Color(0xFF8B5CF6),
    ),
    StatusItem(
      id: 'status_alex',
      authorName: 'Alex',
      content: 'Building secure Flutter apps with Signal E2EE 🚀',
      timestamp: DateTime.now().subtract(const Duration(hours: 5)),
      isViewed: false,
      backgroundColor: const Color(0xFF10B981),
    ),
  ];

  void _addStatus() async {
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController();
        return AlertDialog(
          title: const Text('Add Status Update'),
          content: TextField(
            controller: controller,
            maxLength: 140,
            decoration: const InputDecoration(
              hintText: 'Type a status message...',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('Post'),
            ),
          ],
        );
      },
    );

    if (text != null && text.trim().isNotEmpty) {
      setState(() {
        _statuses.insert(
          0,
          StatusItem(
            id: DateTime.now().toIso8601String(),
            authorName: 'My Status',
            content: text.trim(),
            timestamp: DateTime.now(),
            isMe: true,
            isViewed: true,
            backgroundColor: const Color(0xFF0EA5E9),
          ),
        );
      });
    }
  }

  void _viewStatus(StatusItem status) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Scaffold(
        backgroundColor: status.backgroundColor,
        body: SafeArea(
          child: Stack(
            children: [
              Positioned(
                top: 16,
                left: 16,
                right: 16,
                child: Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: Colors.white24,
                      child: Text(
                        status.authorName[0].toUpperCase(),
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          status.authorName,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                        Text(
                          '24h status',
                          style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 12),
                        ),
                      ],
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    status.content,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final myStatuses = _statuses.where((s) => s.isMe).toList();
    final recentStatuses = _statuses.where((s) => !s.isMe).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Status'),
        actions: [
          IconButton(
            icon: const Icon(Icons.camera_alt_outlined),
            onPressed: _addStatus,
          ),
        ],
      ),
      body: ListView(
        children: [
          ListTile(
            leading: Stack(
              children: [
                CircleAvatar(
                  radius: 26,
                  backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.2),
                  child: Icon(Icons.person, color: theme.colorScheme.primary),
                ),
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: CircleAvatar(
                    radius: 10,
                    backgroundColor: theme.colorScheme.primary,
                    child: const Icon(Icons.add, size: 14, color: Colors.white),
                  ),
                ),
              ],
            ),
            title: const Text('My Status', style: TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(
              myStatuses.isNotEmpty
                  ? 'Tap to view or update status'
                  : 'Tap to add status update',
            ),
            onTap: () {
              if (myStatuses.isNotEmpty) {
                _viewStatus(myStatuses.first);
              } else {
                _addStatus();
              }
            },
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'Recent updates',
              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey, fontSize: 13),
            ),
          ),
          ...recentStatuses.map(
            (status) => ListTile(
              leading: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: status.isViewed ? Colors.grey : theme.colorScheme.primary,
                    width: 2,
                  ),
                ),
                child: CircleAvatar(
                  radius: 24,
                  backgroundColor: status.backgroundColor,
                  child: Text(
                    status.authorName[0].toUpperCase(),
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              title: Text(status.authorName, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(status.content, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => _viewStatus(status),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'add_status_fab',
        onPressed: _addStatus,
        child: const Icon(Icons.edit),
      ),
    );
  }
}
