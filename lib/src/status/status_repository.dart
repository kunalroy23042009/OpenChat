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
  }) async => await client.rpc(
    'publish_status',
    params: {
      'p_type': 'text',
      'p_content': content,
      'p_media_url': null,
      'p_background_color': backgroundColor,
      'p_audience': audience,
      'p_audience_user_ids': <String>[],
    },
  ) as String;

  Future<void> markViewed(String id) =>
      client.rpc('mark_status_viewed', params: {'p_status_id': id});
}
