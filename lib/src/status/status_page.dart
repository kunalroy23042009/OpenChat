import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'status_repository.dart';
import 'video_status_view.dart';

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
    this.mediaType = 'text',
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

  /// 'text', 'image', or 'video'. Cloud text posts sync; media stays local
  /// until the media pipeline lands for status.
  final String mediaType;
}

class StatusPage extends StatefulWidget {
  const StatusPage({super.key, this.client});

  final SupabaseClient? client;

  @override
  State<StatusPage> createState() => _StatusPageState();
}

class _StatusPageState extends State<StatusPage> {
  /// User-created statuses only. No fictional sample entries: the list
  /// starts empty and fills from the + action on this device.
  final List<StatusItem> _statuses = [];

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
            ListTile(
              leading: const Icon(Icons.videocam_outlined),
              title: const Text('Video status'),
              subtitle: const Text('Up to 3 minutes, stays on this device'),
              onTap: () => Navigator.pop(ctx, 'video'),
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
    if (choice == 'video') {
      await _addVideoStatus();
      return;
    }
    const palette = [
      Color(0xFF0EA5E9),
      Color(0xFF8B5CF6),
      Color(0xFF10B981),
      Color(0xFFF59E0B),
      Color(0xFFEF4444),
      Color(0xFF0F172A),
    ];
    var pickedColor = palette.first;
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController();
        return StatefulBuilder(
          builder: (ctx, setDialog) => AlertDialog(
            title: const Text('Add Status Update'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: controller,
                    maxLength: 140,
                    decoration: const InputDecoration(
                      hintText: 'Type a status message...',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final c in palette)
                        InkWell(
                          onTap: () => setDialog(() => pickedColor = c),
                          child: CircleAvatar(
                            radius: 16,
                            backgroundColor: c,
                            child: pickedColor == c
                                ? const Icon(
                                    Icons.check,
                                    size: 16,
                                    color: Colors.white,
                                  )
                                : null,
                          ),
                        ),
                    ],
                  ),
                ],
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
          ),
        );
      },
    );

    if (text != null && text.trim().isNotEmpty) {
      final color = pickedColor;
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
          mediaType: 'image',
        ),
      );
    });
  }

  Future<void> _addVideoStatus() async {
    XFile? picked;
    try {
      picked = await ImagePicker().pickVideo(
        source: ImageSource.gallery,
        maxDuration: const Duration(minutes: 3),
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
          content: 'Video',
          timestamp: DateTime.now(),
          isMe: true,
          isViewed: true,
          backgroundColor: const Color(0xFF0F172A),
          imagePath: picked!.path,
          mediaType: 'video',
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
                              child: status.mediaType == 'video'
                                  ? VideoStatusView(
                                      path: status.imagePath!,
                                    )
                                  : ClipRRect(
                                      borderRadius: BorderRadius.circular(16),
                                      child: Image.file(
                                        File(status.imagePath!),
                                        fit: BoxFit.contain,
                                      ),
                                    ),
                            ),
                          ),
                          if (status.content != 'Photo' &&
                              status.content != 'Video')
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
          if (recentStatuses.isNotEmpty) ...[
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
          )],
          const Divider(thickness: 8, height: 24),
          // Channels arrive with the communities milestone; no fictional
          // entries are shown in the meantime.
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
