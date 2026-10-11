import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'call_repository.dart';
import 'call_screen.dart';
import 'call_service.dart';
import 'call_signaling.dart';

/// Outgoing 1:1 call: permissions → token → join room → ring peer → live
/// screen. Callee accept/decline arrives over Realtime; unanswered rings
/// time out at 60s. Everything is logged to call history exactly once.
Future<void> startOutgoingCall(
  BuildContext context, {
  required SupabaseClient client,
  required String peerId,
  required String peerName,
  required CallType type,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  final service = CallService();
  if (!await service.ensurePermissions(video: type == CallType.video)) {
    messenger.showSnackBar(
      SnackBar(content: Text(service.error ?? 'Permission denied.')),
    );
    service.dispose();
    return;
  }
  final me = client.auth.currentUser!.id;
  final room = callRoomFor(me, peerId);
  late final String url;
  late final String token;
  try {
    final creds = await CallSignaling.token(
      client,
      room: room,
      name: peerName,
    );
    url = creds.url;
    token = creds.token;
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e')));
    service.dispose();
    return;
  }
  late final String inviteId;
  try {
    final invite = await CallSignaling.place(
      client,
      peerId: peerId,
      callType: type == CallType.video ? 'video' : 'voice',
    );
    inviteId = invite.inviteId;
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e')));
    service.dispose();
    return;
  }
  if (!await service.join(
    url: url,
    token: token,
    video: type == CallType.video,
  )) {
    messenger.showSnackBar(
      SnackBar(content: Text(service.error ?? 'Could not start the call.')),
    );
    try {
      await CallSignaling.finish(client, inviteId: inviteId);
    } catch (_) {}
    service.dispose();
    return;
  }

  final session = ActiveCallSession(
    callId: inviteId,
    peerUsername: peerName,
    peerDisplayName: peerName,
    type: type,
    initialState: CallState.ringing,
  );
  final startedAt = DateTime.now();
  var finished = false;
  Timer? timeout;
  RealtimeChannel? watch;

  Future<void> logOnce(String outcome) async {
    try {
      await CallRepository(client).add(
        peerLabel: peerName,
        peerId: peerId,
        callType: type == CallType.video ? 'video' : 'voice',
        outcome: outcome,
        startedAt: startedAt,
        durationSeconds: session.durationSeconds,
      );
    } catch (_) {}
  }

  Future<void> finish(String outcome, {bool pop = true}) async {
    if (finished) return;
    finished = true;
    timeout?.cancel();
    try {
      await watch?.unsubscribe();
    } catch (_) {}
    try {
      await CallSignaling.finish(client, inviteId: inviteId);
    } catch (_) {}
    await service.hangUp();
    await logOnce(outcome);
    service.dispose();
    if (pop) {
      try {
        navigator.pop();
      } catch (_) {}
    }
  }

  watch =
      client.channel('invite:$inviteId')
        ..onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'call_invites',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: inviteId,
          ),
          callback: (payload) {
            if (finished) return;
            if (payload.newRecord['status'] == 'declined') {
              finish('declined');
              messenger.showSnackBar(
                SnackBar(content: Text('$peerName declined the call.')),
              );
            }
          },
        )
        ..subscribe();
  timeout = Timer(const Duration(seconds: 60), () {
    if (finished || service.remoteJoined || session.durationSeconds > 0) {
      return;
    }
    finish('failed');
    messenger.showSnackBar(
      SnackBar(content: Text('$peerName did not answer.')),
    );
  });

  await navigator.push(
    MaterialPageRoute<void>(
      builder: (_) => CallScreen(
        session: session,
        service: service,
        onEndCall: () => finish(
          session.durationSeconds > 0 ? 'completed' : 'failed',
        ),
      ),
    ),
  );
  // Route popped (system back or finish above already ran).
  await finish(session.durationSeconds > 0 ? 'completed' : 'failed', pop: false);
}
