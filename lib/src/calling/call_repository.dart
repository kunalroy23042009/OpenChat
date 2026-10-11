import 'package:supabase_flutter/supabase_flutter.dart';

class CloudCallLog {
  const CloudCallLog({
    required this.id,
    required this.peerLabel,
    required this.callType,
    required this.direction,
    required this.outcome,
    required this.startedAt,
    required this.durationSeconds,
    this.peerId,
  });

  final String id;
  final String peerLabel;
  final String callType;
  final String direction;
  final String outcome;
  final DateTime startedAt;
  final int durationSeconds;

  /// Null for rows logged before peer ids were recorded.
  final String? peerId;

  factory CloudCallLog.fromJson(Map<String, dynamic> json) => CloudCallLog(
    id: json['id'] as String,
    peerLabel: json['peer_label'] as String? ?? 'OpenChat user',
    callType: json['call_type'] as String,
    direction: json['direction'] as String,
    outcome: json['outcome'] as String,
    startedAt: DateTime.parse(json['started_at'] as String),
    durationSeconds: json['duration_seconds'] as int? ?? 0,
    peerId: json['peer_id'] as String?,
  );
}

class CallRepository {
  const CallRepository(this.client);
  final SupabaseClient client;

  Future<List<CloudCallLog>> list() async {
    final rows =
        await client
                .from('call_logs')
                .select()
                .order('started_at', ascending: false)
                .limit(100)
            as List<dynamic>;
    return rows
        .cast<Map<String, dynamic>>()
        .map(CloudCallLog.fromJson)
        .toList();
  }

  Future<void> add({
    required String peerLabel,
    required String callType,
    required String outcome,
    required DateTime startedAt,
    required int durationSeconds,
    String? peerId,
    String direction = 'outgoing',
  }) => client.from('call_logs').insert({
    'owner_id': client.auth.currentUser!.id,
    'peer_id': peerId,
    'peer_label': peerLabel,
    'call_type': callType,
    'direction': direction,
    'outcome': outcome,
    'started_at': startedAt.toUtc().toIso8601String(),
    'duration_seconds': durationSeconds,
  });
}
