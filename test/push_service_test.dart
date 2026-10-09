import 'package:flutter_test/flutter_test.dart';
import 'package:open_chat/src/push/push_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('push stays disabled when native Firebase setup is absent', () async {
    final push = PushService();
    expect(await push.initialize(null), PushState.disabled);
    expect(push.state, PushState.disabled);
  });
}
