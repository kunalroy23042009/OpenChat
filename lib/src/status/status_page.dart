import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'status_repository.dart';

class StatusItem {
  const StatusItem({
    required this.id,
    required this.authorName,
    required this.content,
    required this.timestamp,
    this.isMe = false,
    this.isViewed = false,
    this.backgroundColor = const Color(0xFF245CDB),
    this.imagePath,
  });

  final String id;
  final String authorName;
  final String content;
  final DateTime timestamp;
  final bool isMe;
  final bool isViewed;
  final Color backgroundColor;

  /// Local gallery photo attached to this status (this-device demo for now).
  final String? imagePath;
}

class StatusPage extends StatefulWidget {
  const StatusPage({super.key, this.client});

  final SupabaseClient? client;

  @override
  State<StatusPage> createState() => _StatusPageState();
}

class _StatusPageState extends State<StatusPage> {
  final List<StatusItem> _statuses = [
    StatusItem(
      id: 'my_status_1',
      authorName: 'My Status',
      content: 'Available on OpenChat!',
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

  @override
  void initState() {
    super.initState();
    _loadCloudStatuses();
  }

  Future<void> _loadCloudStatuses() async {
    final client = widget.client;
    if (client?.auth.currentUser == null) return;
    try {
      final cloud = await StatusRepository(client!).activeStatuses();
      if (!mounted) return;
      final me = client.auth.currentUser!.id;
      setState(() {
        _statuses
          ..clear()
          ..addAll(
            cloud.map(
              (status) => StatusItem(
                id: status.id,
                authorName: status.authorId == me ? 'My Status' : 'Contact',
                content: status.content,
                timestamp: status.createdAt,
                isMe: status.authorId == me,
                isViewed: status.authorId == me,
                backgroundColor: Color(status.backgroundColor ?? 0xFF245CDB),
              ),
            ),
          );
      });
    } catch (_) {
      // Keep the local demo feed when the migration is not deployed or offline.
    }
  }

  Future<void> _publishTextToCloud(String text, Color color) async {
    final client = widget.client;
    if (client?.auth.currentUser == null) return;
    try {
      await StatusRepository(client!)
          .publishText(text, backgroundColor: color.toARGB32());
    } catch (_) {
      // The locally-created status remains visible while offline.
    }
  }

  Future<void> _addStatus() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.text_fields_outlined),
              title: const Text('Text status'),
              onTap: () => Navigator.pop(ctx, 'text'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Photo status'),
              onTap: () => Navigator.pop(ctx, 'photo'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'photo') {
      await _addPhotoStatus();
      return;
    }
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
      const color = Color(0xFF0EA5E9);
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
            backgroundColor: color,
          ),
        );
      });
      await _publishTextToCloud(text.trim(), color);
    }
  }

  Future<void> _addPhotoStatus() async {
    XFile? picked;
    try {
      picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        imageQuality: 85,
      );
    } on Exception catch (_) {
      return;
    }
    if (picked == null || !mounted) return;
    setState(() {
      _statuses.insert(
        0,
        StatusItem(
          id: DateTime.now().toIso8601String(),
          authorName: 'My Status',
          content: 'Photo',
          timestamp: DateTime.now(),
          isMe: true,
          isViewed: true,
          backgroundColor: const Color(0xFF0F172A),
          imagePath: picked!.path,
        ),
      );
    });
  }

  void _viewStatus(StatusItem status) {
    if (!status.isMe && widget.client?.auth.currentUser != null) {
      StatusRepository(widget.client!).markViewed(status.id).catchError((_) {});
    }
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
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          status.authorName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        Text(
                          '24h status',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.8),
                            fontSize: 12,
                          ),
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
                child: status.imagePath != null
                    ? Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Flexible(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(16),
                                child: Image.file(
                                  File(status.imagePath!),
                                  fit: BoxFit.contain,
                                ),
                              ),
                            ),
                          ),
                          if (status.content != 'Photo')
                            Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(
                                status.content,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                        ],
                      )
                    : Padding(
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
                  backgroundColor: theme.colorScheme.primary.withValues(
                    alpha: 0.2,
                  ),
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
            title: const Text(
              'My Status',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
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
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.grey,
                fontSize: 13,
              ),
            ),
          ),
          ...recentStatuses.map(
            (status) => ListTile(
              leading: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: status.isViewed
                        ? Colors.grey
                        : const Color(0xFF00A884),
                    width: 2.2,
                  ),
                ),
                child: CircleAvatar(
                  radius: 24,
                  backgroundColor: status.backgroundColor,
                  child: Text(
                    status.authorName[0].toUpperCase(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              title: Text(
                status.authorName,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                status.content,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => _viewStatus(status),
            ),
          ),
          const Divider(thickness: 8, height: 24),
          // WhatsApp Channels Section
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Channels',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                TextButton(
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Exploring all WhatsApp channels'),
                      ),
                    );
                  },
                  child: const Text(
                    'Explore',
                    style: TextStyle(color: Color(0xFF00A884)),
                  ),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Stay updated on topics you care about. Find channels to follow below.',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ),
          const SizedBox(height: 12),
          _ChannelCard(
            name: 'OpenChat News',
            description: 'Official releases, security audits, and news.',
            avatarText: 'OC',
            followers: '1.2M followers',
          ),
          _ChannelCard(
            name: 'Flutter & Dart Weekly',
            description:
                'UI kits, animations, and cross-platform architecture.',
            avatarText: 'FL',
            followers: '850K followers',
          ),
          _ChannelCard(
            name: 'AI Frontier',
            description:
                'ChatGPT, Claude, Gemini & DeepSeek agent intelligence.',
            avatarText: 'AI',
            followers: '2.4M followers',
          ),
          const SizedBox(height: 80),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.small(
            heroTag: 'text_status_fab',
            backgroundColor: Theme.of(context).brightness == Brightness.dark
                ? const Color(0xFF2A3942)
                : const Color(0xFFE9EDEF),
            foregroundColor: Theme.of(context).brightness == Brightness.dark
                ? Colors.white
                : const Color(0xFF128C7E),
            onPressed: () async {
              final text = await showDialog<String>(
                context: context,
                builder: (ctx) {
                  final controller = TextEditingController();
                  return AlertDialog(
                    title: const Text('Add Text Status'),
                    content: TextField(
                      controller: controller,
                      maxLength: 140,
                      decoration: const InputDecoration(
                        hintText: "What's on your mind?",
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Cancel'),
                      ),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00A884),
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () =>
                            Navigator.pop(ctx, controller.text.trim()),
                        child: const Text('Post'),
                      ),
                    ],
                  );
                },
              );
              if (text != null && text.isNotEmpty && mounted) {
                const color = Color(0xFF00A884);
                setState(() {
                  _statuses.insert(
                    0,
                    StatusItem(
                      id: 'status_${DateTime.now().millisecondsSinceEpoch}',
                      authorName: 'My Status',
                      content: text,
                      timestamp: DateTime.now(),
                      isMe: true,
                      isViewed: true,
                      backgroundColor: color,
                    ),
                  );
                });
                await _publishTextToCloud(text, color);
              }
            },
            child: const Icon(Icons.edit, size: 20),
          ),
          const SizedBox(height: 12),
          FloatingActionButton(
            heroTag: 'photo_status_fab',
            backgroundColor: const Color(0xFF00A884),
            foregroundColor: Colors.white,
            onPressed: _addPhotoStatus,
            child: const Icon(Icons.camera_alt),
          ),
        ],
      ),
    );
  }
}

class _ChannelCard extends StatefulWidget {
  const _ChannelCard({
    required this.name,
    required this.description,
    required this.avatarText,
    required this.followers,
  });

  final String name;
  final String description;
  final String avatarText;
  final String followers;

  @override
  State<_ChannelCard> createState() => _ChannelCardState();
}

class _ChannelCardState extends State<_ChannelCard> {
  bool _following = false;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: const Color(0xFF00A884),
        child: Text(
          widget.avatarText,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      title: Row(
        children: [
          Text(
            widget.name,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
          const SizedBox(width: 4),
          const Icon(Icons.verified, color: Color(0xFF00A884), size: 16),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.description,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            widget.followers,
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
      ),
      trailing: OutlinedButton(
        style: OutlinedButton.styleFrom(
          backgroundColor: _following
              ? Colors.transparent
              : const Color(0xFFE7FFDB),
          foregroundColor: const Color(0xFF008069),
          side: const BorderSide(color: Color(0xFF00A884)),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
        onPressed: () {
          setState(() => _following = !_following);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                _following
                    ? 'Followed ${widget.name}'
                    : 'Unfollowed ${widget.name}',
              ),
            ),
          );
        },
        child: Text(
          _following ? 'Following' : 'Follow',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}
