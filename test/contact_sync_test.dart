import 'package:flutter_test/flutter_test.dart';
import 'package:open_chat/src/contacts_sync.dart';

void main() {
  test('normalizePhone keeps valid E.164 and drops the rest', () {
    expect(ContactSyncService.normalizePhone('+14155552671'), '+14155552671');
    expect(ContactSyncService.normalizePhone('+1 415-555-2671'), '+14155552671');
    expect(ContactSyncService.normalizePhone('+91 98765 43210'), '+919876543210');
    // No country code: never guessed.
    expect(ContactSyncService.normalizePhone('4155552671'), isNull);
    expect(ContactSyncService.normalizePhone('04155552671'), isNull);
    // Too short, too long, bad prefix.
    expect(ContactSyncService.normalizePhone('+123456'), isNull);
    expect(ContactSyncService.normalizePhone('+012345678'), isNull);
    expect(ContactSyncService.normalizePhone('+12345678901234567'), isNull);
    expect(ContactSyncService.normalizePhone(''), isNull);
    expect(ContactSyncService.normalizePhone('not a number'), isNull);
  });
}
