import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_chat/src/push/notify_service.dart';

class ShownNotification {
  ShownNotification({
    required this.id,
    this.title,
    this.body,
    this.channelId,
    this.payload,
    this.actions,
  });
  final int id;
  final String? title;
  final String? body;
  final String? channelId;
  final String? payload;
  final List<AndroidNotificationAction>? actions;
}

/// Fake Android implementation: records renders without touching any
/// platform channel, so routing logic is verified, not plugin internals.
class FakeNotifications extends AndroidFlutterLocalNotificationsPlugin {
  final shown = <ShownNotification>[];
  final channels = <String>[];

  @override
  Future<bool> initialize({
    required AndroidInitializationSettings settings,
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback?
    onDidReceiveBackgroundNotificationResponse,
  }) async => true;

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    AndroidNotificationDetails? notificationDetails,
    String? payload,
  }) async {
    shown.add(
      ShownNotification(
        id: id,
        title: title,
        body: body,
        channelId: notificationDetails?.channelId,
        payload: payload,
        actions: notificationDetails?.actions,
      ),
    );
  }

  @override
  Future<void> cancel({required int id, String? tag}) async {
    shown.removeWhere((n) => n.id == id);
  }

  @override
  Future<void> createNotificationChannel(
    AndroidNotificationChannel notificationChannel,
  ) async {
    channels.add(notificationChannel.id);
  }
}

void main() {
  test('notification ids separate message/status and stay deterministic', () {
    expect(
      NotifyService.notificationId('msg', 'peer'),
      NotifyService.notificationId('msg', 'peer'),
    );
    expect(
      NotifyService.notificationId('msg', 'peer'),
      isNot(NotifyService.notificationId('status', 'peer')),
    );
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeNotifications fake;

  setUp(() {
    fake = FakeNotifications();
    FlutterLocalNotificationsPlatform.instance = fake;
  });

  test('tap payload round-trips and rejects junk', () {
    const tap = NotifyTap(kind: 'msg', peer: 'peer-1', name: 'Al "Q"');
    final back = NotifyTap.decode(tap.encode())!;
    expect(back.kind, 'msg');
    expect(back.peer, 'peer-1');
    expect(back.name, 'Al "Q"');
    expect(NotifyTap.decode(null), isNull);
    expect(NotifyTap.decode(''), isNull);
    expect(NotifyTap.decode('not json'), isNull);
    expect(NotifyTap.decode('{"kind":"nuke","peer":"x"}'), isNull);
    expect(NotifyTap.decode('{"kind":"msg"}'), isNull);
    final group = NotifyTap.decode(
      const NotifyTap(
        kind: 'group',
        peer: 'group-1',
        name: 'Study group',
      ).encode(),
    )!;
    expect((group.kind, group.peer), ('group', 'group-1'));
  });

  test('routing decision suppresses open chats and self echoes', () {
    expect(
      NotifyService.shouldNotifyMessage(
        myId: 'me',
        senderId: 'peer',
        openPeers: {},
      ),
      isTrue,
    );
    expect(
      NotifyService.shouldNotifyMessage(
        myId: 'me',
        senderId: 'peer',
        openPeers: {'peer'},
      ),
      isFalse,
    );
    expect(
      NotifyService.shouldNotifyMessage(
        myId: 'me',
        senderId: 'me',
        openPeers: {},
      ),
      isFalse,
    );
    expect(
      NotifyService.shouldNotifyMessage(
        myId: 'me',
        senderId: '',
        openPeers: {},
      ),
      isFalse,
    );
  });

  test('channels are created and renders land on the right one', () async {
    await NotifyService.instance.init();
    expect(
      fake.channels,
      containsAll([
        NotifyService.messagesChannel,
        NotifyService.silentMessagesChannel,
        NotifyService.callsChannel,
        NotifyService.statusChannel,
        NotifyService.groupsChannel,
      ]),
    );
    await NotifyService.instance.showMessage(peerId: 'peer-1', name: 'Alice');
    await NotifyService.instance.showCall(
      inviteId: 'invite-1',
      name: 'Bob',
      video: true,
    );
    await NotifyService.instance.showStatus(
      authorId: 'peer-2',
      name: 'Cara',
      snippet: 'Hello world',
    );
    await NotifyService.instance.showMessage(
      peerId: 'peer-silent',
      name: 'Dora',
      silent: true,
    );
    await NotifyService.instance.showGroup(
      groupId: 'group-1',
      groupName: 'Study group',
      senderName: 'Eli',
    );
    expect(fake.shown, hasLength(5));

    final message = fake.shown[0];
    expect(message.actions!.single.id, 'reply');
    expect(message.actions!.single.showsUserInterface, isTrue);
    expect(message.channelId, NotifyService.messagesChannel);
    expect(message.title, 'Alice');
    final messageTap = NotifyTap.decode(message.payload)!;
    expect((messageTap.kind, messageTap.peer), ('msg', 'peer-1'));

    final call = fake.shown[1];
    expect(call.channelId, NotifyService.callsChannel);
    expect(call.title, contains('video'));

    final status = fake.shown[2];
    expect(status.channelId, NotifyService.statusChannel);
    expect(status.title, contains('Cara'));
    expect(status.body, 'Hello world');

    final silent = fake.shown[3];
    expect(silent.channelId, NotifyService.silentMessagesChannel);
    final group = fake.shown[4];
    expect(group.channelId, NotifyService.groupsChannel);
    expect(NotifyTap.decode(group.payload)?.peer, 'group-1');
  });

  test('open chats suppress their own notifications', () async {
    await NotifyService.instance.init();
    NotifyService.instance.openChats.add('peer-1');
    await NotifyService.instance.showMessage(peerId: 'peer-1', name: 'Alice');
    expect(fake.shown, isEmpty);
    NotifyService.instance.openChats.remove('peer-1');
    await NotifyService.instance.showMessage(peerId: 'peer-1', name: 'Alice');
    expect(fake.shown, hasLength(1));
  });

  test(
    'reply uses the platform action id rather than payload instructions',
    () {
      const payload =
          '{"kind":"msg","peer":"alice","name":"Alice","action":"reply"}';
      expect(NotifyTap.decode(payload)!.action, isNull);
      final reply = NotifyTap.fromResponse(
        const NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          payload: payload,
          actionId: 'reply',
        ),
      );
      expect(reply!.action, 'reply');
      expect(reply.peer, 'alice');
      expect(
        NotifyTap.decode(
          const NotifyTap(
            kind: 'missed_call',
            peer: 'call',
            name: 'Alice',
          ).encode(),
        )!.kind,
        'missed_call',
      );
    },
  );

  test(
    'visible groups suppress alerts without consuming event deduplication',
    () async {
      final service = NotifyService.instance;
      await service.init();
      service.openGroups.add('visible');
      await service.showGroup(
        groupId: 'visible',
        groupName: 'Group',
        senderName: 'Alice',
        event: 'event-1',
      );
      expect(fake.shown, isEmpty);
      service.openGroups.remove('visible');
      await service.showGroup(
        groupId: 'visible',
        groupName: 'Group',
        senderName: 'Alice',
        event: 'event-1',
      );
      expect(fake.shown, hasLength(1));
      await service.cancelGroup('visible');
      expect(fake.shown, isEmpty);
    },
  );
}
