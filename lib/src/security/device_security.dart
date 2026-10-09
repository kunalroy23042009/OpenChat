import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class DeviceIdentityStatus {
  const DeviceIdentityStatus({
    required this.initialized,
    required this.libraryVersion,
    this.fingerprint,
    this.hardwareBacked = false,
  });
  final bool initialized;
  final String libraryVersion;
  final String? fingerprint;
  final bool hardwareBacked;
  factory DeviceIdentityStatus.fromMap(Map<Object?, Object?> data) =>
      DeviceIdentityStatus(
        initialized: data['initialized'] as bool,
        libraryVersion: data['libraryVersion'] as String,
        fingerprint: data['fingerprint'] as String?,
        hardwareBacked: data['hardwareBacked'] as bool? ?? false,
      );
}

class DeviceSecurity {
  static const channel = MethodChannel('dev.openchat/security');
  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  Future<DeviceIdentityStatus> status(String accountId) async =>
      DeviceIdentityStatus.fromMap(
        (await channel.invokeMapMethod<Object?, Object?>('status', {
          'accountId': accountId,
        }))!,
      );
  Future<DeviceIdentityStatus> initialize(String accountId) async =>
      DeviceIdentityStatus.fromMap(
        (await channel.invokeMapMethod<Object?, Object?>('initialize', {
          'accountId': accountId,
        }))!,
      );
  Future<Map<String, bool>> selfTest() async {
    final result = (await channel.invokeMapMethod<String, Object?>(
      'selfTest',
    ))!;
    return {
      for (final key in const [
        'roundTrip',
        'oneTimePreKeyConsumed',
        'outOfOrder',
        'replayRejected',
        'tamperRejected',
        'identityChangeRejected',
      ])
        key: result[key] == true,
    };
  }
}
