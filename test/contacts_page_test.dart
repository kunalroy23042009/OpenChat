import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_chat/src/contacts_page.dart';
import 'package:open_chat/src/contacts_repository.dart';

class FakeContactsRepository implements ContactsRepository {
  AccountProfile account = const AccountProfile(
    name: 'Me',
    username: 'myname',
    about: 'Hey there!',
  );
  List<CloudContact> rows = [
    const CloudContact(
      userId: 'friend',
      requestId: 'request',
      name: 'Taylor',
      username: 'taylor',
      about: 'Coffee first.',
      status: 'pending',
      incoming: true,
    ),
  ];
  bool fail = false;
  @override
  Future<AccountProfile> profile() async {
    if (fail) throw Exception('offline');
    return account;
  }

  @override
  Future<List<CloudContact>> contacts() async => rows;
  @override
  Future<void> saveProfile(String name, String username, String about) async {
    account = AccountProfile(name: name, username: username, about: about);
  }

  @override
  Future<String> invite(String username) async => 'rate_limited';
  @override
  Future<String> inviteByPhone(String phone) async => 'rate_limited';
  @override
  Future<void> respond(String requestId, bool accept) async {
    rows = [
      CloudContact(
        userId: 'friend',
        requestId: requestId,
        name: 'Taylor',
        username: 'taylor',
        about: 'Coffee first.',
        status: accept ? 'accepted' : 'declined',
        incoming: true,
      ),
    ];
  }

  @override
  Future<void> block(String userId) async {}
  @override
  Future<void> unblock(String userId) async {}
  @override
  Future<void> cancelInvite(String requestId) async {
    rows.removeWhere((r) => r.requestId == requestId);
  }

  @override
  Future<void> deleteAccount() async {
    rows.clear();
  }
}

void main() {
  testWidgets('accepting a received invitation updates the contact list', (
    tester,
  ) async {
    final repository = FakeContactsRepository();
    await tester.pumpWidget(
      MaterialApp(home: ContactsPage(repository: repository)),
    );
    await tester.pumpAndSettle();
    await tester.dragUntilVisible(
      find.text('Accept'),
      find.byType(ListView),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();
    expect(repository.rows.single.status, 'accepted');
    expect(find.text('Accept'), findsNothing);
    expect(find.text('Taylor'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('failed profile load offers retry and recovers', (tester) async {
    final repository = FakeContactsRepository()..fail = true;
    await tester.pumpWidget(
      MaterialApp(home: ContactsPage(repository: repository)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Save profile'), findsNothing);
    repository.fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Save profile'), findsOneWidget);
  });
  testWidgets('server invitation rate limit is shown to the user', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: ContactsPage(repository: FakeContactsRepository())),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Send invitation'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Their exact username'),
      'taylor',
    );
    await tester.pumpAndSettle();
    await Scrollable.ensureVisible(
      tester.element(find.text('Send invitation')),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send invitation'));
    await tester.pumpAndSettle();
    expect(
      find.text('Daily invitation limit reached. Try again tomorrow (UTC).'),
      findsOneWidget,
    );
  });
  testWidgets('contact about lines render and profile about saves', (
    tester,
  ) async {
    final repository = FakeContactsRepository();
    await tester.pumpWidget(
      MaterialApp(home: ContactsPage(repository: repository)),
    );
    await tester.pumpAndSettle();
    await tester.dragUntilVisible(
      find.text('Coffee first.'),
      find.byType(ListView),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    expect(find.text('Coffee first.'), findsOneWidget);
    await tester.dragUntilVisible(
      find.widgetWithText(TextFormField, 'About'),
      find.byType(ListView),
      const Offset(0, 300),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'About'),
      'Updated about line',
    );
    await tester.pumpAndSettle();
    await Scrollable.ensureVisible(
      tester.element(find.text('Save profile')),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save profile'));
    await tester.pumpAndSettle();
    expect(repository.account.about, 'Updated about line');
    expect(tester.takeException(), isNull);
  });
}
