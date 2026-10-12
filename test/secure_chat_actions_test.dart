import 'dart:async';
import 'dart:convert';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:open_chat/src/chat_store.dart';
import 'package:open_chat/src/local_profile.dart';
import 'package:open_chat/src/media/media_message.dart';
import 'package:open_chat/src/push/push_service.dart';
import 'package:open_chat/src/secure_chat_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const me = '00000000-0000-4000-8000-000000000001';
  const peer = '00000000-0000-4000-8000-000000000002';
  const channel = MethodChannel('dev.openchat/security');
  late SupabaseClient client;
  late ChatStore store;
  late SharedPreferences prefs;
  final encryptedPlaintexts = <String>[];
  var rejectSend = false;

  setUp(() async {
    rejectSend = false;
    encryptedPlaintexts.clear();
    SharedPreferences.setMockInitialValues({
      'openchat.keysPublished.v1.$me': true,
    });
    prefs = await SharedPreferences.getInstance();
    store = ChatStore(prefs);
    final expires =
        DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
        1000;
    final token =
        '${base64UrlEncode(utf8.encode('{"alg":"HS256"}')).replaceAll('=', '')}.'
        '${base64UrlEncode(utf8.encode(jsonEncode({'sub': me, 'exp': expires}))).replaceAll('=', '')}.test';
    client = SupabaseClient(
      'https://example.test',
      'test-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        Object response = [];
        if (request.url.path.contains('/auth/')) {
          response = {
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
          };
        } else if (request.url.path.endsWith('enqueue_message')) {
          response = {
            'status': rejectSend ? 'unavailable' : 'sent',
            'created_at': DateTime.now().toUtc().toIso8601String(),
          };
        } else if (request.url.path.endsWith('mark_messages_read') ||
            request.url.path.endsWith('ack_messages')) {
          response = 1;
        }
        return http.Response(
          jsonEncode(response),
          200,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    await client.auth.signInWithPassword(
      email: 'test@example.test',
      password: 'test-password',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'signalHasSession') return {'hasSession': true};
          if (call.method == 'signalEncrypt') {
            encryptedPlaintexts.add(
              utf8.decode(
                base64Decode((call.arguments as Map)['plain'] as String),
              ),
            );
            return {
              'type': 2,
              'body': base64Encode([1, 2, 3]),
            };
          }
          return <String, dynamic>{};
        });
    await store.addSecureMessage(
      me,
      peer,
      'Original message',
      mine: true,
      clientId: 'original',
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await client.dispose();
    store.dispose();
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SecureChatScreen(
          profile: LocalProfile(prefs),
          store: store,
          push: PushService(),
          client: client,
          peerId: peer,
          peerName: 'Alice',
          peerUsername: 'alice',
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> disposeScreen(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    // Cancels realtime's deferred disconnect timer; no clock pump after
    // this point, so no retry/backoff timer can fire and hang the test.
    unawaited(client.realtime.disconnect());
    // Flush the socket close-handshake timeout (6s) and any poke timeout
    // (8s): connState is disconnected, so no reconnect timer is armed.
    await tester.pump(const Duration(seconds: 10));
  }

  testWidgets(
    'long press replies with a quote and clears the composer on success',
    (tester) async {
      await open(tester);
      await tester.longPress(find.text('Original message'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reply'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Cancel reply'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'My reply');
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(store.getSecureConversation(me, peer), hasLength(2));
      final body = parseMessageBody(encryptedPlaintexts.single);
      expect(body.isReply, isTrue);
      expect(body.text, 'My reply');
      expect(body.quoteText, 'Original message');
      expect(find.byTooltip('Cancel reply'), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await disposeScreen(tester);
    },
  );

  testWidgets(
    'failed deletion leaves history unchanged and failed sends retain drafts',
    (tester) async {
      rejectSend = true;
      await open(tester);
      await tester.longPress(find.text('Original message'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Delete for everyone'),
        150,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.text('Delete for everyone'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(
        store.getSecureConversation(me, peer).single.text,
        'Original message',
      );
      await tester.enterText(find.byType(TextField), 'Keep my draft');
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Keep my draft',
      );
      expect(tester.takeException(), isNull);
      await disposeScreen(tester);
    },
  );

  testWidgets('tapping a bubble pops the quick reaction bar', (tester) async {
    await open(tester);
    await tester.tap(find.text('Original message'));
    // Single-tap waits out the double-tap deadline before firing.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    // WhatsApp's six quick emojis plus the keyboard button, no dialog.
    for (final e in ['❤️', '😂', '😮', '😢', '🙏', '👍']) {
      expect(find.text(e), findsOneWidget);
    }
    expect(find.byIcon(Icons.add), findsOneWidget);
    await tester.tap(find.text('😂'));
    await tester.pumpAndSettle();
    final reacted = parseMessageBody(encryptedPlaintexts.single);
    expect(reacted.isReact, isTrue);
    expect(reacted.text, '😂');
    expect(reacted.removed, isFalse);
    expect(store.secureReactions(me, peer)['out:original'], {'😂': 'mine'});
    expect(tester.takeException(), isNull);
    await disposeScreen(tester);
  });

  testWidgets('plus button opens the full emoji keyboard', (tester) async {
    await open(tester);
    await tester.tap(find.text('Original message'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.byType(EmojiPicker), findsOneWidget);
    // Dismiss without choosing; nothing is transmitted.
    await tester.tapAt(const Offset(400, 100));
    await tester.pumpAndSettle();
    expect(encryptedPlaintexts, isEmpty);
    expect(find.byType(EmojiPicker), findsNothing);
    expect(tester.takeException(), isNull);
    await disposeScreen(tester);
  });

  testWidgets('reacting adds a chip and transmits explicit state', (
    tester,
  ) async {
    await open(tester);
    await tester.longPress(find.text('Original message'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('React'));
    await tester.pumpAndSettle();
    // Menu React opens the full keyboard; tapping any cell reacts.
    expect(find.byType(EmojiPicker), findsOneWidget);
    expect(find.byType(EmojiCell), findsWidgets);
    await tester.tap(find.byType(EmojiCell).first);
    await tester.pumpAndSettle();
    final reacted = parseMessageBody(encryptedPlaintexts.single);
    expect(reacted.isReact, isTrue);
    expect(reacted.text, isNotEmpty);
    expect(reacted.removed, isFalse);
    final votes = store.secureReactions(me, peer)['out:original']!;
    expect(votes, hasLength(1));
    final emoji = votes.keys.single;
    expect(find.text(emoji), findsWidgets);
    // Tapping the chip again removes the reaction.
    await tester.tap(find.text(emoji).first);
    // The parent also supports double-tap; let its single-tap deadline pass.
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    final cleared = parseMessageBody(encryptedPlaintexts.last);
    expect(cleared.removed, isTrue);
    expect(store.secureReactions(me, peer), isEmpty);
    expect(tester.takeException(), isNull);
    await disposeScreen(tester);
  });

  testWidgets('editing replaces the message without adding a row', (
    tester,
  ) async {
    await open(tester);
    await tester.longPress(find.text('Original message'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Edit'),
      150,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Editing message'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Corrected message');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    final edited = parseMessageBody(encryptedPlaintexts.single);
    expect(edited.isEdit, isTrue);
    expect(edited.text, 'Corrected message');
    final history = store.getSecureConversation(me, peer);
    expect(history, hasLength(1));
    expect(history.single.text, 'Corrected message');
    expect(find.text('Editing message'), findsNothing);
    expect(tester.takeException(), isNull);
    await disposeScreen(tester);
  });

  testWidgets('double tap sends an author-qualified heart reaction', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('Original message'));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.text('Original message'));
    await tester.pumpAndSettle();
    final reaction = parseMessageBody(encryptedPlaintexts.single);
    expect(reaction.target, '$me:original');
    expect(reaction.text, '❤️');
    expect(store.secureReactions(me, peer)['out:original'], {'❤️': 'mine'});
    await disposeScreen(tester);
  });
}
