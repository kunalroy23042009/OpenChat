import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'status_repository.dart';
import 'video_status_view.dart';
import '../contacts_repository.dart'
    show CloudContact, SupabaseContactsRepository;
import '../local_profile.dart';
import '../ops/error_report.dart';
import '../push/notify_service.dart';
import '../security/app_lock.dart';

/// Human "time ago" label, WhatsApp-style ("Just now", "5 min ago").
String statusTimeAgo(DateTime when) {
  final age = DateTime.now().difference(when);
  if (age.inMinutes < 1) return 'Just now';
  if (age.inMinutes < 60) return '${age.inMinutes} min ago';
  if (age.inHours < 24) return '${age.inHours} h ago';
  return '${age.inDays} d ago';
}

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
    this.authorId,
    this.avatarUrl,
    this.cloudMediaUrl,
  });

  final String id;
  final String authorName;
  final String content;
  final DateTime timestamp;
  final bool isMe;
  final bool isViewed;
  final Color backgroundColor;
  final String? authorId;
  final String? avatarUrl;

  /// Gallery photo/video attached to this status. Local file for this-device
  /// drafts, null for cloud statuses (render [cloudMediaUrl] instead).
  final String? imagePath;

  /// Signed cloud URL for image/video statuses published to the
  /// `status-media` bucket (refreshed on each load; signing lasts 1h).
  final String? cloudMediaUrl;

  /// 'text', 'image', or 'video'. Text and cloud media sync; local drafts
  /// are uploaded before the status is shared.
  final String mediaType;
}

class StatusPage extends StatefulWidget {
  const StatusPage({super.key, this.client, this.profile});

  final SupabaseClient? client;

  /// Signed-in profile powering the "My Status" avatar/photo.
  final LocalProfile? profile;

  @override
  State<StatusPage> createState() => _StatusPageState();
}

class _StatusPageState extends State<StatusPage> {
  /// User-created statuses only. No fictional sample entries: the list
  /// starts empty and fills from the + action on this device.
  final List<StatusItem> _statuses = [];
  RealtimeChannel? _statusChannel;

  /// Mirrors the Privacy setting "Status". 'contacts' | 'except' | 'only'.
  String _statusPrivacy = 'contacts';

  @override
  void initState() {
    super.initState();
    _loadPrivacy();
    _loadCloudStatuses();
    _subscribeStatusUpdates();
  }

  Future<void> _loadPrivacy() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value =
          prefs.getString('openchat.privacy.statusPrivacy') ?? 'contacts';
      if (mounted && value != _statusPrivacy) {
        setState(() => _statusPrivacy = value);
      }
    } catch (_) {}
  }

  void _subscribeStatusUpdates() {
    final client = widget.client;
    if (client?.auth.currentUser == null) return;
    _statusChannel = client!.channel('status_updates')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'status_updates',
        callback: (payload) => _onStatusInsert(payload.newRecord),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'status_updates',
        callback: (payload) => _onStatusUpdate(payload.newRecord),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.delete,
        schema: 'public',
        table: 'status_updates',
        callback: (payload) => _onStatusDelete(payload.oldRecord),
      )
      ..subscribe();
  }

  Future<void> _onStatusInsert(Map<String, dynamic> record) async {
    await _refreshStatusFromRecord(record);
  }

  Future<void> _onStatusUpdate(Map<String, dynamic> record) async {
    await _refreshStatusFromRecord(record);
  }

  Future<void> _onStatusDelete(Map<String, dynamic> record) async {
    if (!mounted) return;
    setState(() {
      _statuses.removeWhere((s) => s.id == record['id']);
    });
  }

  Future<void> _refreshStatusFromRecord(Map<String, dynamic> record) async {
    final client = widget.client;
    if (client?.auth.currentUser == null) return;
    try {
      final status = CloudStatus.fromJson(record);
      final repo = StatusRepository(client!);
      final contacts = await SupabaseContactsRepository(client).contacts();
      final byId = {for (final c in contacts) c.userId: c};
      final me = client.auth.currentUser!.id;
      final isMe = status.authorId == me;
      final contact = byId[status.authorId];
      final name = isMe
          ? 'My Status'
          : (contact != null && contact.name.isNotEmpty
              ? contact.name
              : 'Contact');
      final media = await _resolveMedia(repo, status);
      if (!mounted) return;
      setState(() {
        _statuses.removeWhere((s) => s.id == status.id);
        _statuses.insert(
          0,
          StatusItem(
            id: status.id,
            authorName: name,
            content: status.content,
            timestamp: status.createdAt,
            isMe: isMe,
            isViewed: isMe,
            backgroundColor: Color(status.backgroundColor ?? 0xFF245CDB),
            authorId: status.authorId,
            avatarUrl: contact?.avatarUrl,
            cloudMediaUrl: media.$1,
            mediaType: media.$2,
          ),
        );
      });
    } catch (_) {}
  }

  /// Signed URL + rendered media type for a cloud status ('' => non-media).
  static const (String?, String) _noMedia = (null, 'text');

  Future<(String?, String)> _resolveMedia(
    StatusRepository repo,
    CloudStatus status,
  ) async {
    final url = await repo.signedMediaUrl(status.mediaUrl);
    if (url == null) return _noMedia;
    return (url, status.type == 'video' ? 'video' : 'image');
  }

  @override
  void dispose() {
    _statusChannel?.unsubscribe();
    super.dispose();
  }

  Future<void> _loadCloudStatuses() async {
    final client = widget.client;
    if (client?.auth.currentUser == null) return;
    try {
      final repo = StatusRepository(client!);
      final cloud = await repo.activeStatuses();
      // Resolve real names/photos through contacts (profiles are
      // self-read-only, so this is the accessible source of truth).
      Map<String, CloudContact> byId = {};
      try {
        final contacts = await SupabaseContactsRepository(client).contacts();
        byId = {for (final c in contacts) c.userId: c};
      } catch (_) {}
      final resolved = <(String, (String?, String))>[];
      for (final status in cloud) {
        // Signing is sequential-but-cheap; batch through the awaited list to
        // keep rows stable.
        resolved.add((status.id, await _resolveMedia(repo, status)));
      }
      final mediaById = {for (final r in resolved) r.$1: r.$2};
      if (!mounted) return;
      final me = client.auth.currentUser!.id;
      setState(() {
        _statuses
          ..clear()
          ..addAll(
            cloud.map((status) {
              final isMe = status.authorId == me;
              final contact = byId[status.authorId];
              final name = isMe
                  ? 'My Status'
                  : (contact != null && contact.name.isNotEmpty
                        ? contact.name
                        : 'Contact');
              final media = mediaById[status.id] ?? _noMedia;
              return StatusItem(
                id: status.id,
                authorName: name,
                content: status.content,
                timestamp: status.createdAt,
                isMe: isMe,
                isViewed: isMe,
                backgroundColor: Color(status.backgroundColor ?? 0xFF245CDB),
                authorId: status.authorId,
                avatarUrl: contact?.avatarUrl,
                cloudMediaUrl: media.$1,
                mediaType: media.$2,
              );
            }),
          );
      });
    } catch (_) {
      // Keep the local demo feed when the migration is not deployed or offline.
    }
  }

  Future<void> _publishTextToCloud(String text, Color color) async {
    final client = widget.client;
    if (client?.auth.currentUser == null) return;
    // Resolve the audience from the account's Status privacy setting.
    var audience = 'contacts';
    List<String> audienceIds = const [];
    try {
      final prefs = await SharedPreferences.getInstance();
      audience = prefs.getString('openchat.privacy.statusPrivacy') ?? 'contacts';
    } catch (_) {}
    if (audience == 'only' || audience == 'except') {
      if (!mounted) return;
      final picked = await _pickAudience(audience);
      if (picked == null) return; // cancelled
      audienceIds = picked;
    }
    try {
      await StatusRepository(client!).publishText(
        text,
        backgroundColor: color.toARGB32(),
        audience: audience,
        audienceUserIds: audienceIds,
      );
      // Fan out to contacts' devices; foreground ones alert via realtime.
      unawaited(NotifyService.poke(client, kind: 'status'));
    } catch (_) {
      // The locally-created status remains visible while offline.
    }
  }

  /// Lets the user choose which contacts to include ('only') or exclude
  /// ('except'). Returns the selected ids, or null when cancelled.
  Future<List<String>?> _pickAudience(String mode) async {
    final client = widget.client;
    if (client == null) return const [];
    List<CloudContact> contacts = const [];
    try {
      contacts = await SupabaseContactsRepository(
        client,
      ).contacts().then((all) => all.where((c) => c.status == 'accepted').toList());
    } catch (_) {}
    if (!mounted) return null;
    final selected = <String>{};
    final result = await showModalBottomSheet<List<String>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
                child: Text(
                  mode == 'only'
                      ? 'Share with these contacts only'
                      : 'Hide from these contacts',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Flexible(
                child: contacts.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('No accepted contacts yet.'),
                      )
                    : ListView(
                        shrinkWrap: true,
                        children: [
                          for (final c in contacts)
                            CheckboxListTile(
                              value: selected.contains(c.userId),
                              title: Text(c.name),
                              subtitle: Text('@${c.username}'),
                              onChanged: (checked) => setLocal(() {
                                if (checked == true) {
                                  selected.add(c.userId);
                                } else {
                                  selected.remove(c.userId);
                                }
                              }),
                            ),
                        ],
                      ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: mode == 'only' && selected.isEmpty
                        ? null
                        : () => Navigator.pop(ctx, selected.toList()),
                    child: const Text('Done'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return result;
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
              subtitle: const Text('Up to 3 minutes, shared to your audience'),
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
    await _pickAndPublishMedia(false);
  }

  Future<void> _addVideoStatus() async {
    await _pickAndPublishMedia(true);
  }

  /// Picks gallery media, previews it locally at once, then uploads to the
  /// private `status-media` bucket and publishes the cloud row. A failure
  /// keeps the local preview and shows why nothing reached contacts.
  Future<void> _pickAndPublishMedia(bool isVideo) async {
    XFile? picked;
    AppLock.suppressRelockOnce = true;
    try {
      picked = isVideo
          ? await ImagePicker().pickVideo(
              source: ImageSource.gallery,
              maxDuration: const Duration(minutes: 3),
            )
          : await ImagePicker().pickImage(
              source: ImageSource.gallery,
              maxWidth: 1600,
              imageQuality: 85,
            );
    } on Exception catch (_) {
      return;
    }
    if (picked == null || !mounted) return;
    final file = File(picked.path);
    final localId = 'local_${DateTime.now().microsecondsSinceEpoch}';
    setState(() {
      _statuses.insert(
        0,
        StatusItem(
          id: localId,
          authorName: 'My Status',
          content: isVideo ? 'Video' : 'Photo',
          timestamp: DateTime.now(),
          isMe: true,
          isViewed: true,
          backgroundColor: const Color(0xFF0F172A),
          imagePath: picked!.path,
          mediaType: isVideo ? 'video' : 'image',
        ),
      );
    });
    await _publishMediaToCloud(isVideo: isVideo, file: file, localId: localId);
  }

  /// Upload + publish attempt for a locally previewed media status. On
  /// success the local placeholder is replaced by the cloud row; on failure
  /// it stays and a reason is surfaced.
  Future<void> _publishMediaToCloud({
    required bool isVideo,
    required File file,
    required String localId,
  }) async {
    final client = widget.client;
    if (client?.auth.currentUser == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Sign in to share this status with your contacts.'),
          ),
        );
      }
      return;
    }
    var audience = 'contacts';
    List<String> audienceIds = const [];
    try {
      final prefs = await SharedPreferences.getInstance();
      audience = prefs.getString('openchat.privacy.statusPrivacy') ?? 'contacts';
    } catch (_) {}
    if (audience == 'only' || audience == 'except') {
      if (!mounted) return;
      final picked = await _pickAudience(audience);
      if (picked == null) return; // cancelled: keep local preview only
      audienceIds = picked;
    }
    try {
      await StatusRepository(client!).publishMedia(
        file,
        isVideo: isVideo,
        backgroundColor: 0xFF0F172A,
        audience: audience,
        audienceUserIds: audienceIds,
      );
      if (mounted) {
        setState(() => _statuses.removeWhere((s) => s.id == localId));
        await _loadCloudStatuses();
      }
      unawaited(NotifyService.poke(client, kind: 'status'));
    } catch (e) {
      ErrorReport.reportError('status-media', e, code: 'publish');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Saved on this device, but could not reach the server to share it. '
              'Check your connection and try again.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _deleteStatus(BuildContext ctx, StatusItem status) async {
    final confirmed = await showDialog<bool>(
      context: ctx,
      builder: (d) => AlertDialog(
        title: const Text('Delete status?'),
        content: const Text('It disappears for everyone immediately.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // Cloud rows delete server-side (author-only RLS); local-only gallery
    // items just drop from this device.
    final client = widget.client;
    if (client?.auth.currentUser != null && status.imagePath == null) {
      final repo = StatusRepository(client!);
      try {
        await repo.deleteStatus(status.id);
      } catch (_) {}
      // Best-effort cleanup of the bucket object the row pointed at.
      try {
        final url = status.cloudMediaUrl ?? '';
        if (url.contains('status-media/')) {
          final objectPath = Uri.parse(url).pathSegments
              .skipWhile((s) => s != 'object')
              .skip(2) // object + signed prefix
              .join('/');
          if (objectPath.isNotEmpty) {
            await client.storage.from('status-media').remove([objectPath]);
          }
        }
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _statuses.removeWhere((s) => s.id == status.id);
    });
    if (ctx.mounted) Navigator.pop(ctx);
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
                      foregroundImage: (status.avatarUrl ?? '').isNotEmpty
                          ? NetworkImage(status.avatarUrl!)
                          : null,
                      child: Text(
                        status.authorName.isEmpty
                            ? '?'
                            : status.authorName[0].toUpperCase(),
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
                    if (status.isMe)
                      IconButton(
                        tooltip: 'Delete status',
                        icon: const Icon(
                          Icons.delete_outline,
                          color: Colors.white,
                        ),
                        onPressed: () => _deleteStatus(ctx, status),
                      ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
              Center(
                child: _statusMediaBody(status),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Full-bleed status body: local draft media, cloud media (signed URL),
  /// or the text-only fallback. Media keeps an optional caption.
  Widget _statusMediaBody(StatusItem status) {
    Widget? media;
    if (status.imagePath != null) {
      media = status.mediaType == 'video'
          ? VideoStatusView(path: status.imagePath!)
          : ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.file(File(status.imagePath!), fit: BoxFit.contain),
            );
    } else if (status.cloudMediaUrl != null) {
      media = status.mediaType == 'video'
          ? VideoStatusView(url: status.cloudMediaUrl)
          : ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.network(
                status.cloudMediaUrl!,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => _statusTextBody(status),
              ),
            );
    }
    if (media == null) return _statusTextBody(status);
    final placeholderLabel =
        status.content == 'Photo' || status.content == 'Video';
    return Container(
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: media,
            ),
          ),
          if (!placeholderLabel && status.content.isNotEmpty)
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
      ),
    );
  }

  Widget _statusTextBody(StatusItem status) => Padding(
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
  );

  Widget _statusAvatar(StatusItem status, double radius) {
    final url = status.avatarUrl;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: status.isViewed ? Colors.grey : const Color(0xFF00A884),
          width: 2.2,
        ),
      ),
      child: CircleAvatar(
        radius: radius,
        backgroundColor: status.backgroundColor,
        foregroundImage: (url != null && url.isNotEmpty)
            ? NetworkImage(url)
            : null,
        child: Text(
          status.authorName.isEmpty ? '?' : status.authorName[0].toUpperCase(),
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  /// Own profile photo in the "My Status" row; falls back to a person glyph.
  Widget _myStatusAvatar(ThemeData theme) {
    final profile = widget.profile;
    if (profile == null) {
      return CircleAvatar(
        radius: 26,
        backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.2),
        child: Icon(Icons.person, color: theme.colorScheme.primary),
      );
    }
    return ListenableBuilder(
      listenable: profile,
      builder: (context, _) {
        final file = profile.avatarFile;
        return CircleAvatar(
          radius: 26,
          backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.2),
          foregroundImage: file != null ? FileImage(file) : null,
          child: Icon(Icons.person, color: theme.colorScheme.primary),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final myStatuses = _statuses.where((s) => s.isMe).toList();
    final freshStatuses = _statuses
        .where((s) => !s.isMe && !s.isViewed)
        .toList();
    final seenStatuses = _statuses.where((s) => !s.isMe && s.isViewed).toList();

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
                _myStatusAvatar(theme),
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
          if (freshStatuses.isEmpty && seenStatuses.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'No updates yet. Status appears here once accepted contacts post — add people by username in People first.',
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
            ),
          if (freshStatuses.isNotEmpty) ...[
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
            ...freshStatuses.map(
              (status) => ListTile(
                leading: _statusAvatar(status, 24),
                title: Text(
                  status.authorName,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  statusTimeAgo(status.timestamp),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  _viewStatus(status);
                  setState(() {
                    final i = _statuses.indexWhere((s) => s.id == status.id);
                    if (i >= 0) {
                      final s = _statuses[i];
                      _statuses[i] = StatusItem(
                        id: s.id,
                        authorName: s.authorName,
                        content: s.content,
                        timestamp: s.timestamp,
                        isMe: s.isMe,
                        isViewed: true,
                        backgroundColor: s.backgroundColor,
                        imagePath: s.imagePath,
                        mediaType: s.mediaType,
                        authorId: s.authorId,
                        avatarUrl: s.avatarUrl,
                      );
                    }
                  });
                },
              ),
            ),
          ],
          if (seenStatuses.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Viewed updates',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.grey,
                  fontSize: 13,
                ),
              ),
            ),
            ...seenStatuses.map(
              (status) => ListTile(
                leading: _statusAvatar(status, 24),
                title: Text(
                  status.authorName,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  statusTimeAgo(status.timestamp),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => _viewStatus(status),
              ),
            ),
          ],
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
