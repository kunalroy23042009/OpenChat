import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_chat/src/security/device_security.dart';
import 'package:open_chat/src/security/security_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(DeviceSecurity.channel, null),
  );

  testWidgets(
    'signed-in user can initialize identity without exporting private data',
    (tester) async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DeviceSecurity.channel, (call) async {
            calls.add(call);
            return {
              'initialized': call.method == 'initialize',
              'libraryVersion': '0.105.0',
              if (call.method == 'initialize')
                'fingerprint': 'public-fingerprint',
              'hardwareBacked': true,
            };
          });
      await tester.pumpWidget(
        const MaterialApp(home: SecurityPage(accountId: 'account')),
      );
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(
        tester.element(find.text('Create device identity')),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create device identity'));
      await tester.pumpAndSettle();
      expect(find.text('Local identity created'), findsOneWidget);
      expect(calls.map((c) => c.method), ['status', 'initialize']);
      expect(calls.last.arguments, {'accountId': 'account'});
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'native failure is visible and does not claim encryption success',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            DeviceSecurity.channel,
            (_) async => throw PlatformException(
              code: 'SECURITY_FAILED',
              message: 'Existing keys were not replaced.',
            ),
          );
      await tester.pumpWidget(
        const MaterialApp(home: SecurityPage(accountId: 'account')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Existing keys were not replaced.'), findsOneWidget);
      expect(find.text('Local identity created'), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('unsupported platforms do not call the native bridge', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          DeviceSecurity.channel,
          (_) async => fail('Bridge must not be called'),
        );
    await tester.pumpWidget(
      const MaterialApp(home: SecurityPage(accountId: 'account')),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Native encryption is currently available on Android only. iOS and web integration are pending.',
      ),
      findsOneWidget,
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
