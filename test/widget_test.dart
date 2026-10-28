import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:open_chat/main.dart';
import 'package:open_chat/src/chat_store.dart';
import 'package:open_chat/src/local_profile.dart';
import 'package:open_chat/src/push/push_service.dart';
import 'package:open_chat/src/security/app_lock.dart';

void main() {
  setUp(() {
    AppLock.testBypass = true;
    AppLock.enabled.value = false;
  });
  testWidgets('wide layout opens chat alongside searchable list', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final store = ChatStore(preferences);
    await tester.pumpWidget(
      OpenChatApp(
        store: store,
        profile: LocalProfile(preferences),
        preferences: preferences,
        onboardingComplete: true,
        push: PushService(),
      ),
    );
    await tester.tap(find.text('Maya Chen'));
    await tester.pumpAndSettle();
    expect(find.text('Maya Chen'), findsNWidgets(2));
    await tester.enterText(
      find.widgetWithText(TextField, 'Search conversations'),
      'Leo',
    );
    await tester.pumpAndSettle();
    expect(find.text('Leo Martins'), findsOneWidget);
    expect(find.text('Aisha Patel'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('small phone new-chat opens real contacts, not a demo dialog', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final store = ChatStore(preferences);
    await tester.pumpWidget(
      OpenChatApp(
        store: store,
        profile: LocalProfile(preferences),
        preferences: preferences,
        onboardingComplete: true,
        push: PushService(),
      ),
    );
    await tester.tap(find.byTooltip('New conversation'));
    await tester.pumpAndSettle();
    // Without a signed-in account the button points at sign-in instead of
    // fabricating a fictional conversation. Real chats come from contacts.
    expect(find.text('Sign in to start chatting.'), findsOneWidget);
    expect(find.text('New demo conversation'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opens a conversation and persists a locally sent message', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final store = ChatStore(preferences);
    await tester.pumpWidget(
      OpenChatApp(
        store: store,
        profile: LocalProfile(preferences),
        preferences: preferences,
        onboardingComplete: true,
        push: PushService(),
      ),
    );
    await tester.tap(find.text('Maya Chen'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Write a message…'),
      'Saturday works for me',
    );
    await tester.tap(find.byTooltip('Send message'));
    await tester.pumpAndSettle();
    expect(find.text('Saturday works for me'), findsOneWidget);
    final restored = ChatStore(preferences);
    expect(
      restored.conversations.first.messages.last.text,
      'Saturday works for me',
    );
    expect(restored.conversations.first.unread, 0);
  });
  testWidgets('short landscape layout does not overflow', (tester) async {
    tester.view.physicalSize = const Size(900, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final store = ChatStore(preferences);
    await tester.pumpWidget(
      OpenChatApp(
        store: store,
        profile: LocalProfile(preferences),
        preferences: preferences,
        onboardingComplete: true,
        push: PushService(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Your profile photo'), findsOneWidget);
    expect(find.textContaining('Good conversations'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test(
    'blank messages are ignored and corrupt data recovers visibly',
    () async {
      SharedPreferences.setMockInitialValues({ChatStore.storageKey: 'broken'});
      final preferences = await SharedPreferences.getInstance();
      final store = ChatStore(preferences);
      expect(store.storageWarning, isNotNull);
      final chat = store.conversations.first;
      final count = chat.messages.length;
      await store.send(chat, '   ');
      expect(chat.messages.length, count);
    },
  );
}
