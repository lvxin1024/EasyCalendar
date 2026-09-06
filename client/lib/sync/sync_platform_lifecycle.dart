import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract interface class SyncPlatformLifecycle {
  Future<void> start();

  Future<void> close();
}

class MethodChannelSyncPlatformLifecycle implements SyncPlatformLifecycle {
  const MethodChannelSyncPlatformLifecycle({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('io.easycalendar/sync_lifecycle');

  final MethodChannel _channel;

  @override
  Future<void> start() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await _channel.invokeMethod<void>('startForegroundSync');
  }

  @override
  Future<void> close() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await _channel.invokeMethod<void>('stopForegroundSync');
  }
}

class NoopSyncPlatformLifecycle implements SyncPlatformLifecycle {
  const NoopSyncPlatformLifecycle();

  @override
  Future<void> start() async {}

  @override
  Future<void> close() async {}
}
