import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_chat/main.dart';
import 'package:open_chat/src/chat_store.dart';
import 'package:open_chat/src/local_profile.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> pumpApp(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    OpenChatApp(
      store: ChatStore(preferences),
      profile: LocalProfile(preferences),
      preferences: preferences,
      onboardingComplete: false,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('first launch walks welcome, account skip, and profile setup', (
    tester,
  ) async {
    await pumpApp(tester);
    expect(find.textContaining('Welcome to'), findsOneWidget);

    await tester.tap(find.text('Agree and continue'));
    await tester.pumpAndSettle();
    expect(find.text('Your account.'), findsOneWidget);
    expect(find.text('Continue to profile setup'), findsOneWidget);

    await tester.tap(find.text('Continue to profile setup'));
    await tester.pumpAndSettle();
    expect(find.text('Say hello.'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Your name'), 'Sam');
    await tester.tap(find.text('Start chatting'));
    await tester.pumpAndSettle();
    expect(find.text('open chat'), findsOneWidget);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool('openchat.onboarding.v1'), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile setup requires a name', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Agree and continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue to profile setup'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start chatting'));
    await tester.pumpAndSettle();
    expect(find.text('Enter your name to continue.'), findsOneWidget);
    expect(find.text('open chat'), findsNothing);
  });

  testWidgets('returning users skip onboarding', (tester) async {
    SharedPreferences.setMockInitialValues({'openchat.onboarding.v1': true});
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      OpenChatApp(
        store: ChatStore(preferences),
        profile: LocalProfile(preferences),
        preferences: preferences,
        onboardingComplete: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('open chat'), findsOneWidget);
    expect(find.textContaining('Welcome to'), findsNothing);
  });
}
