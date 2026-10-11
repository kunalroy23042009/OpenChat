import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_chat/src/chat/conversation_repository.dart';
import 'package:open_chat/src/chat/team_tools_page.dart';

void main() {
  testWidgets('resource vault categorizes shared conversation content', (
    tester,
  ) async {
    final messages = [
      GroupMessage(
        id: 'document',
        conversationId: 'conversation',
        senderId: 'sender',
        content: 'requirements.pdf',
        type: 'document',
        createdAt: DateTime(2026),
      ),
      GroupMessage(
        id: 'link',
        conversationId: 'conversation',
        senderId: 'sender',
        content: 'See https://example.com/spec',
        type: 'text',
        createdAt: DateTime(2026),
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(home: ResourceVaultPage(messages: messages)),
    );

    expect(find.text('requirements.pdf'), findsOneWidget);
    await tester.tap(find.text('Links'));
    await tester.pumpAndSettle();
    expect(find.text('See https://example.com/spec'), findsOneWidget);
  });
}
