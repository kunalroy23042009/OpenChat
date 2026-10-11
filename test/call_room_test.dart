import 'package:flutter_test/flutter_test.dart';
import 'package:open_chat/src/calling/call_service.dart';

void main() {
  test('call rooms are deterministic per pair', () {
    const a = '11111111-1111-1111-1111-111111111111';
    const b = '22222222-2222-2222-2222-222222222222';
    expect(callRoomFor(a, b), callRoomFor(b, a));
    expect(callRoomFor(a, b), 'dm_${a}_$b');
  });

  test('room names differ per pair', () {
    expect(
      callRoomFor(
        '11111111-1111-1111-1111-111111111111',
        '22222222-2222-2222-2222-222222222222',
      ),
      isNot(
        callRoomFor(
          '11111111-1111-1111-1111-111111111111',
          '33333333-3333-3333-3333-333333333333',
        ),
      ),
    );
  });
}
