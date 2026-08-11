import 'package:flutter/widgets.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'app.dart';
import 'application/item_controller.dart';
import 'config/app_config.dart';
import 'data/local_item_repository.dart';
import 'sync/connectivity_monitor.dart';
import 'sync/http_sync_transport.dart';
import 'sync/sync_coordinator.dart';
import 'sync/token_store.dart';
import 'widget/widget_deep_link_controller.dart';
import 'widget/widget_snapshot_writer.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = AppConfig.fromEnvironment();
  tz_data.initializeTimeZones();
  tz.setLocalLocation(tz.getLocation(config.timezone));
  await initializeDateFormatting('zh_CN');
  final repository = LocalItemRepository(config);
  final syncCoordinator = SyncCoordinator(
    repository: repository,
    transport: HttpSyncTransport(),
    tokenStore: SecureSyncTokenStore(),
    connectivityMonitor: PlatformConnectivityMonitor(),
    deviceId: config.deviceId,
    retryLimit: config.syncRetryLimit,
  );
  final controller = ItemController(
    repository: repository,
    config: config,
    syncCoordinator: syncCoordinator,
    widgetSnapshotWriter: const PlatformWidgetSnapshotWriter(),
  );
  await controller.initialize();
  final widgetDeepLinks = WidgetDeepLinkController();
  await widgetDeepLinks.start();
  runApp(
    EasyCalendarApp(
      config: config,
      controller: controller,
      widgetDeepLinks: widgetDeepLinks,
    ),
  );
}
