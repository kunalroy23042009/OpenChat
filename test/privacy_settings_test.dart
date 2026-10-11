import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_chat/src/privacy_settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('privacy choices persist locally without a cloud account', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      MaterialApp(home: PrivacySettingsPage(preferences: preferences)),
    );

    expect(find.text('Privacy and sessions'), findsOneWidget);
    await tester.tap(find.text('Read receipts'));
    await tester.pump();
    expect(preferences.getBool('openchat.privacy.readReceipts'), isFalse);

    await tester.tap(find.text('Default disappearing timer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('90 days'));
    await tester.pumpAndSettle();
    expect(preferences.getInt('openchat.privacy.disappearing'), 7776000);
  });
}
