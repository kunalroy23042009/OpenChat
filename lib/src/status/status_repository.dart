import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

class CloudStatus {
  const CloudStatus({
    required this.id,
    required this.authorId,
    required this.type,
    required this.content,
    required this.createdAt,
    this.mediaUrl,
    this.backgroundColor,
  });

  final String id;
  final String authorId;

  /// 'text', 'image', or 'video'.
  final String type;
  final String content;
  final String? mediaUrl;
  final int? backgroundColor;
  final DateTime createdAt;

  factory CloudStatus.fromJson(Map<String, dynamic> json) => CloudStatus(
    id: json['id'] as String,
    authorId: json['author_id'] as String,
    type: json['type'] as String,
    content: json['content'] as String? ?? 'Media status',
    mediaUrl: json['media_url'] as String?,
    backgroundColor: json['background_color'] as int?,
    createdAt: DateTime.parse(json['created_at'] as String),
  );
}

class StatusRepository {
  const StatusRepository(this.client);
  final SupabaseClient client;

  Future<List<CloudStatus>> activeStatuses() async {
    final rows =
        await client
                .from('status_updates')
                .select()
                .gt('expires_at', DateTime.now().toUtc().toIso8601String())
                .order('created_at', ascending: false)
            as List<dynamic>;
    return rows.cast<Map<String, dynamic>>().map(CloudStatus.fromJson).toList();
  }

  Future<String> publishText(
    String content, {
    int? backgroundColor,
    String audience = 'contacts',
    List<String> audienceUserIds = const [],
  }) async => await client.rpc(
    'publish_status',
    params: {
      'p_type': 'text',
      'p_content': content,
      'p_media_url': null,
      'p_background_color': backgroundColor,
      'p_audience': audience,
      'p_audience_user_ids': audienceUserIds,
    },
  ) as String;

  /// Uploads a gallery photo/video to the private `status-media` bucket and
  /// publishes a cloud status for it. The bucket's RLS lets only the author
  /// and the status audience read the object; the visible row mirrors that.
  ///
  /// Path contract: `<author-uid>/<unique-name><ext>`, media_url stored as
  /// `status-media/` + path. Returns the created status id.
  Future<String> publishMedia(
    File media, {
    required bool isVideo,
    String? caption,
    int? backgroundColor,
    String audience = 'contacts',
    List<String> audienceUserIds = const [],
  }) async {
    final user = client.auth.currentUser;
    if (user == null) {
      throw StateError('Sign in to share a status with your contacts.');
    }
    final extension = p.extension(media.path).toLowerCase();
    final contentType = isVideo
        ? switch (extension) {
            '.mov' => 'video/quicktime',
            '.webm' => 'video/webm',
            _ => 'video/mp4',
          }
        : switch (extension) {
            '.png' => 'image/png',
            '.webp' => 'image/webp',
            _ => 'image/jpeg',
          };
    final name =
        '${user.id}/status_${DateTime.now().microsecondsSinceEpoch}$extension';
    await client.storage
        .from('status-media')
        .upload(
          name,
          media,
          fileOptions: FileOptions(contentType: contentType, upsert: false),
        );
    try {
      return await client.rpc(
        'publish_status',
        params: {
          'p_type': isVideo ? 'video' : 'image',
          'p_content': caption ?? (isVideo ? 'Video status' : 'Photo status'),
          'p_media_url': 'status-media/$name',
          'p_background_color': backgroundColor,
          'p_audience': audience,
          'p_audience_user_ids': audienceUserIds,
        },
      ) as String;
    } catch (e) {
      // Keep storage consistent: a status row that never landed should not
      // leave an orphaned object behind.
      try {
        await client.storage.from('status-media').remove([name]);
      } catch (_) {}
      rethrow;
    }
  }

  /// Turns a stored `media_url` value into a temporary signed URL for
  /// image/network viewers. Values that are not bucket paths (legacy plain
  /// URLs) are returned untouched; signing failures return null (offline).
  Future<String?> signedMediaUrl(String? mediaUrl) async {
    if (mediaUrl == null || mediaUrl.isEmpty) return null;
    const prefix = 'status-media/';
    if (!mediaUrl.startsWith(prefix)) return mediaUrl;
    final path = mediaUrl.substring(prefix.length);
    try {
      return await client.storage
          .from('status-media')
          .createSignedUrl(path, 60 * 60);
    } catch (_) {
      return null;
    }
  }

  Future<void> markViewed(String id) =>
      client.rpc('mark_status_viewed', params: {'p_status_id': id});

  /// The "Viewed by" list for one of the user's own statuses. Server RPC
  /// enforces authorship; profile fields ride along so RLS-on-profiles
  /// (self-select only) never blocks the names.
  Future<List<Map<String, dynamic>>> viewers(String id) async {
    final rows = await client.rpc(
      'status_viewers',
      params: {'p_status_id': id},
    );
    return (rows as List)
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();
  }

  Future<void> deleteStatus(String id) =>
      client.from('status_updates').delete().eq('id', id);
}
