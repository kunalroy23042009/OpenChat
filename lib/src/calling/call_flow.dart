import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../push/notify_service.dart';
import '../security/signal_crypto.dart';
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
  final mediaKey = base64UrlEncode(
    List<int>.generate(32, (_) => Random.secure().nextInt(256)),
  ).replaceAll('=', '');
  String friendlyCallError(Object e) {
    final msg = e.toString();
    // place_call raises 'Contact unavailable' when the pair has no accepted
    // contact request (or a block either way). Say what to do, not just no.
    if (msg.contains('Contact unavailable')) {
      return 'Not connected yet. Add $peerName in People by username, wait for accept, then call.';
    }
    return msg.replaceFirst('Exception: ', '');
  }

  late final String encryptedCallKey;
  try {
    encryptedCallKey = await SignalCrypto(
      client: client,
      accountId: me,
      preferences: await SharedPreferences.getInstance(),
    ).encryptText(peerId, mediaKey);
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Could not establish encrypted calling: $e')),
    );
    service.dispose();
    return;
  }
  // Place the invite first so the per-call room exists; the token function
  // only mints credentials for a live invitation.
  late final String inviteId;
  late final String room;
  try {
    final invite = await CallSignaling.place(
      client,
      peerId: peerId,
      callType: type == CallType.video ? 'video' : 'voice',
      encryptedCallKey: encryptedCallKey,
    );
    inviteId = invite.inviteId;
    room = invite.room;
    // Ring a killed/background callee via FCM; foreground callees ring
    // through their realtime invite watcher instead.
    unawaited(
      NotifyService.poke(
        client,
        kind: 'call',
        peer: peerId,
        invite: inviteId,
        video: type == CallType.video,
      ),
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(friendlyCallError(e))));
    service.dispose();
    return;
  }
  late final String url;
  late final String token;
  try {
    final creds = await CallSignaling.token(client, room: room, name: peerName);
    url = creds.url;
    token = creds.token;
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e')));
    try {
      await CallSignaling.finish(client, inviteId: inviteId);
    } catch (_) {}
    service.dispose();
    return;
  }
  if (!await service.join(
    url: url,
    token: token,
    video: type == CallType.video,
    mediaKey: mediaKey,
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

  watch = client.channel('invite:$inviteId')
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
        final status = payload.newRecord['status'];
        if (status == 'declined') {
          finish('declined');
          messenger.showSnackBar(
            SnackBar(content: Text('$peerName declined the call.')),
          );
        } else if (status == 'ended') {
          // Remote hangup (before or during the call): end locally too
          // instead of stranding this side on a dead call screen.
          final connected = service.remoteJoined || session.durationSeconds > 0;
          finish(connected ? 'completed' : 'failed');
          if (!connected) {
            messenger.showSnackBar(
              SnackBar(content: Text('$peerName ended the call.')),
            );
          }
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
        onEndCall: () =>
            finish(session.durationSeconds > 0 ? 'completed' : 'failed'),
      ),
    ),
  );
  // Route popped (system back or finish above already ran).
  await finish(
    session.durationSeconds > 0 ? 'completed' : 'failed',
    pop: false,
  );
}
