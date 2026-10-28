import 'package:flutter_test/flutter_test.dart';
import 'package:open_chat/src/contacts_repository.dart';

void main() {
  test('contact parses avatar_url when the listing provides one', () {
    final contact = CloudContact.fromJson({
      'user_id': 'u1',
      'request_id': 'r1',
      'display_name': 'Ava',
      'username': 'ava',
      'about': 'Hi',
      'avatar_url': 'https://example.test/avatars/u1/avatar.jpg',
      'status': 'accepted',
      'incoming': false,
    });
    expect(contact.avatarUrl, 'https://example.test/avatars/u1/avatar.jpg');
  });

  test('contact avatar is null for legacy listings without avatar_url', () {
    final contact = CloudContact.fromJson({
      'user_id': 'u1',
      'display_name': 'Ava',
      'username': 'ava',
      'status': 'accepted',
      'incoming': false,
    });
    expect(contact.avatarUrl, isNull);
  });

  test('contact retains a private avatar path before it is signed', () {
    final contact = CloudContact.fromJson({
      'user_id': 'u1',
      'display_name': 'Ava',
      'username': 'ava',
      'avatar_path': 'u1/avatar_1.jpg',
      'status': 'accepted',
      'incoming': false,
    });
    expect(contact.avatarPath, 'u1/avatar_1.jpg');
    expect(contact.avatarUrl, isNull);
  });
}
