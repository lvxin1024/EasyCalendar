import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'app.dart';
import 'application/cycle_controller.dart';
import 'application/item_controller.dart';
import 'config/app_config.dart';
import 'data/local_cycle_repository.dart';
import 'data/local_item_repository.dart';
import 'notification/platform_notification_adapter.dart';
import 'notification/notification_service.dart';
import 'platform/application_identity.dart';
import 'sync/connectivity_monitor.dart';
import 'sync/http_sync_transport.dart';
import 'sync/sync_coordinator.dart';
import 'sync/token_store.dart';
import 'widget/widget_deep_link_controller.dart';
import 'widget/widget_snapshot_writer.dart';
import 'window/desktop_window_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await migrateLegacyWindowsApplicationSupportDirectory();
  tz_data.initializeTimeZones();
  String? systemTimezone;
  try {
    final candidate = (await FlutterTimezone.getLocalTimezone()).identifier;
    tz.getLocation(candidate);
    systemTimezone = candidate;
  } catch (_) {
    // The bundled fallback keeps startup available on unsupported platforms.
  }
  final config = AppConfig.fromEnvironment(
    systemLocale: WidgetsBinding.instance.platformDispatcher.locale,
    systemTimezone: systemTimezone,
  );
  tz.setLocalLocation(tz.getLocation(config.timezone));
  await initializeDateFormatting('zh_CN');
  final repository = LocalItemRepository(config);
  final cycleController = CycleController(
    repository: LocalCycleRepository(
      databaseProvider: repository.openSharedDatabase,
      syncOutboxWriter: repository.writeCycleSyncOutbox,
    ),
  );
  final desktopWindowController = DesktopWindowController();
  final notificationAdapter = PlatformNotificationAdapter();
  final notificationService = NotificationService(adapter: notificationAdapter);
  final syncCoordinator = SyncCoordinator(
    repository: repository,
    transport: HttpSyncTransport(),
    tokenStore: SecureSyncTokenStore(),
    connectivityMonitor: PlatformConnectivityMonitor(),
    deviceId: config.deviceId,
    retryLimit: config.syncRetryLimit,
  );
  syncCoordinator.addListener(() {
    if (syncCoordinator.snapshot.localDataChanged &&
        cycleController.initialized) {
      unawaited(cycleController.refresh().catchError((_) {}));
    }
  });
  final controller = ItemController(
    repository: repository,
    config: config,
    syncCoordinator: syncCoordinator,
    widgetSnapshotWriter: const PlatformWidgetSnapshotWriter(),
    desktopWindowController: desktopWindowController,
    notificationService: notificationService,
  );
  await controller.initialize();
  await cycleController.initialize();
  await notificationService.initialize();
  if (controller.preferences.notificationsEnabled) {
    unawaited(notificationService.reconcileAll(controller.items));
  }
  final widgetDeepLinks = WidgetDeepLinkController();
  await widgetDeepLinks.start();
  runApp(
    EasyCalendarApp(
      config: config,
      controller: controller,
      cycleController: cycleController,
      widgetDeepLinks: widgetDeepLinks,
    ),
  );
}
