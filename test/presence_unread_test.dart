import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:open_chat/src/chat/app_presence.dart';
import 'package:open_chat/src/chat/direct_unread.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const me = '00000000-0000-4000-8000-000000000001';

  Future<SupabaseClient> signedIn(
    Future<http.Response> Function(http.Request) respond,
  ) async {
    final expiry =
        DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
        1000;
    String part(Object value) =>
        base64UrlEncode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final token =
        '${part({'alg': 'HS256'})}.${part({'sub': me, 'exp': expiry})}.test';
    final client = SupabaseClient(
      'https://example.test',
      'test-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        if (!request.url.path.contains('/auth/')) {
          final response = await respond(request);
          return http.Response.bytes(
            response.bodyBytes,
            response.statusCode,
            headers: response.headers,
            request: request,
          );
        }
        return http.Response(
          jsonEncode({
            'access_token': token,
            'refresh_token': 'test-refresh',
            'token_type': 'bearer',
            'expires_in': 3600,
            'user': {
              'id': me,
              'aud': 'authenticated',
              'created_at': DateTime.now().toIso8601String(),
              'app_metadata': {},
              'user_metadata': {},
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    await client.auth.signInWithPassword(
      email: 'test@example.test',
      password: 'test',
    );
    addTearDown(client.dispose);
    return client;
  }

  test(
    'unread counts RPC preserves snapshot offline',
    () async {
      var fail = false;
      var empty = false;
      var pages = 0;
      final client = await signedIn((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/rest/v1/rpc/direct_unread_counts');
        if (fail) return http.Response('offline', 503);
        pages++;
        final rows = empty ? <String, int>{} : {'alice': 500, 'bob': 1};
        return http.Response(
          jsonEncode(rows),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final unread = DirectUnread(client);
      addTearDown(unread.dispose);
      await unread.refresh();
      expect(pages, 1);
      expect(unread.counts, {'alice': 500, 'bob': 1});
      fail = true;
      await unread.refresh();
      expect(unread.counts, {'alice': 500, 'bob': 1});
      fail = false;
      empty = true;
      await unread.refresh();
      expect(unread.counts, isEmpty);
    },
  );

  test('late unread response cannot notify a disposed screen', () async {
    final response = Completer<http.Response>();
    final client = await signedIn((_) => response.future);
    final unread = DirectUnread(client);
    var changes = 0;
    unread.addListener(() => changes++);
    final loading = unread.refresh();
    unread.dispose();
    response.complete(
      http.Response(
        '[{"id":"1","sender_id":"alice"}]',
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    await loading;
    expect(changes, 0);
  });

  testWidgets('presence follows foreground, background and disposal', (
    tester,
  ) async {
    final online = <bool>[];
    final paths = <String>[];
    final client = (await tester.runAsync(() => signedIn((request) async {
      paths.add(request.url.path);
      online.add((jsonDecode(request.body) as Map)['p_is_online'] as bool);
      return http.Response(
        'null',
        200,
        headers: {'content-type': 'application/json'},
      );
    })))!;
    final presence = AppPresence(client)..start();
    addTearDown(presence.dispose);
    await tester.pump();
    presence.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    expect(online.last, isTrue);
    presence.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump();
    expect(online.last, isFalse);
    final pausedCount = online.length;
    await tester.pump(const Duration(minutes: 3));
    expect(online.length, pausedCount);
    presence.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    expect(online.last, isTrue);
    presence.dispose();
    await tester.pump();
    expect(online.last, isFalse);
    final disposedCount = online.length;
    await tester.pump(const Duration(minutes: 3));
    expect(online.length, disposedCount);
    expect(paths, everyElement('/rest/v1/rpc/update_presence'));
  });
}
