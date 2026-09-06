import 'package:easy_calendar/sync/sync_platform_lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('noop lifecycle is safe for desktop and test environments', () async {
    const lifecycle = NoopSyncPlatformLifecycle();
    await lifecycle.start();
    await lifecycle.close();
  });
}
