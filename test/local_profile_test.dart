import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_chat/src/local_profile.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('name and about persist, empty about falls back to default', () async {
    SharedPreferences.setMockInitialValues({});
    final profile = LocalProfile(await SharedPreferences.getInstance());
    await profile.save(name: '  Sam  ', about: '  ');
    expect(profile.name, 'Sam');
    expect(profile.about, LocalProfile.defaultAbout);
    final restored = LocalProfile(await SharedPreferences.getInstance());
    expect(restored.name, 'Sam');
    expect(restored.about, LocalProfile.defaultAbout);
  });

  test('blank names and overlong about lines are rejected', () async {
    SharedPreferences.setMockInitialValues({});
    final profile = LocalProfile(await SharedPreferences.getInstance());
    await expectLater(
      profile.save(name: '   ', about: 'ok'),
      throwsArgumentError,
    );
    await expectLater(
      profile.save(name: 'Sam', about: 'x' * 141),
      throwsArgumentError,
    );
  });

  test('avatar is copied into app storage and cleaned up', () async {
    SharedPreferences.setMockInitialValues({});
    final temp = await Directory.systemTemp.createTemp('openchat-avatar-test');
    addTearDown(() async {
      try {
        await temp.delete(recursive: true);
      } catch (_) {
        // Best-effort cleanup.
      }
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => temp.path,
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          ),
    );
    final source = File('${temp.path}/source.png');
    await source.writeAsBytes(List.generate(256, (i) => i % 256));

    final profile = LocalProfile(await SharedPreferences.getInstance());
    await profile.setAvatar(source.path);
    expect(profile.avatarPath, isNotNull);
    expect(profile.avatarPath, startsWith(p.join(temp.path, 'avatars')));
    expect(File(profile.avatarPath!).existsSync(), isTrue);

    final first = profile.avatarPath!;
    await profile.setAvatar(source.path);
    expect(File(first).existsSync(), isFalse);

    await profile.removeAvatar();
    expect(profile.avatarPath, isNull);
    expect(profile.avatarFile, isNull);
  });

  test('missing avatar file resets to no photo', () async {
    SharedPreferences.setMockInitialValues({
      LocalProfile.avatarKey: '/nonexistent/avatar.png',
    });
    final profile = LocalProfile(await SharedPreferences.getInstance());
    expect(profile.avatarPath, isNull);
  });
}
