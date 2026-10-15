import 'package:supabase_flutter/supabase_flutter.dart';

import 'call_service.dart';

/// Call invitation signaling over the `call_invites` table + RPCs.
/// Rooms are deterministic per pair; tokens come from the livekit-token
/// Edge Function and are never stored.
class CallSignaling {
  /// Caller side: rings [peerId] and returns invite id + room.
  static Future<({String inviteId, String room})> place(
    SupabaseClient client, {
    required String peerId,
    required String callType,
    required String encryptedCallKey,
  }) async {
    final result = await client.rpc(
      'place_call',
      params: {
        'p_callee_id': peerId,
        'p_type': callType,
        'p_encrypted_call_key': encryptedCallKey,
      },
    ) as Map<String, dynamic>;
    return (inviteId: result['id'] as String, room: result['room'] as String);
  }

  static Future<void> answer(
    SupabaseClient client, {
    required String inviteId,
    required bool accept,
  }) => client.rpc(
    'answer_call',
    params: {'p_invite_id': inviteId, 'p_accept': accept},
  );

  static Future<void> finish(
    SupabaseClient client, {
    required String inviteId,
  }) => client.rpc('end_call', params: {'p_invite_id': inviteId});

  /// Exchanges the Supabase session for a short-lived LiveKit token.
  /// Throws a human-readable message when calling is not configured.
  static Future<({String url, String token})> token(
    SupabaseClient client, {
    required String room,
    required String name,
  }) async {
    if (!isValidCallRoom(room)) {
      throw StateError('This call is no longer available.');
    }
    try {
      final response = await client.functions.invoke(
        'livekit-token',
        body: {'room': room, 'name': name},
      );
      final data = response.data;
      if (data is Map<String, dynamic>) {
        final url = data['url'];
        final token = data['token'];
        if (url is String &&
            url.isNotEmpty &&
            token is String &&
            token.isNotEmpty) {
          return (url: url, token: token);
        }
        final error = data['error'];
        if (error is String && error.isNotEmpty) throw StateError(error);
      }
      throw StateError('Calling is unavailable. Try again.');
    } on FunctionException catch (e) {
      final detail = e.details;
      if (detail is Map<String, dynamic> && detail['error'] is String) {
        throw StateError(detail['error'] as String);
      }
      throw StateError('Calling is unavailable (code ${e.status}).');
    }
  }
}
