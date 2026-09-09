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
import 'domain/cycle_record.dart';
import 'notification/platform_notification_adapter.dart';
import 'notification/notification_service.dart';
import 'platform/application_identity.dart';
import 'sync/connectivity_monitor.dart';
import 'sync/group_sync_transport.dart';
import 'sync/http_sync_transport.dart';
import 'sync/iroh_group_sync_peer.dart';
import 'sync/p2p_bridge.dart';
import 'sync/sync_authority.dart';
import 'sync/sync_authority_engine.dart';
import 'sync/sync_coordinator.dart';
import 'sync/sync_group.dart';
import 'sync/sync_group_store.dart';
import 'sync/sync_platform_lifecycle.dart';
import 'sync/sync_transport_selector.dart';
import 'sync/token_store.dart';
import 'utils/configured_time.dart';
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
  final syncProfileStore = SecureSyncGroupProfileStore();
  final syncEndpointIdentityStore = SecureSyncEndpointIdentityStore();
  final syncEndpointKeyStore = SecureSyncEndpointKeyStore();
  final syncGroupSetup = SyncGroupSetupController(
    syncProfileStore,
    endpointIdentityStore: syncEndpointIdentityStore,
    endpointKeyStore: syncEndpointKeyStore,
  );
  late final ItemController controller;
  final syncTransport = SyncTransportSelector(
    cloudTransport: HttpSyncTransport(),
    groupTransportFactory: () async {
      final profile = await syncProfileStore.read();
      if (profile == null) return null;
      final endpointSecret = await syncEndpointKeyStore.read();
      if (endpointSecret == null) return null;
      final bridge = IsolateP2pBridge();
      final storedEndpointId = await syncEndpointIdentityStore.read();
      final endpointId = storedEndpointId ?? controller.preferences.deviceId;
      await bridge.start(
        endpointId: endpointId,
        groupId: profile.groupId,
        endpointSecret: endpointSecret,
      );
      final actualEndpointId = await bridge.endpointId();
      if (actualEndpointId != storedEndpointId) {
        await syncEndpointIdentityStore.write(actualEndpointId);
      }
      final authority = profile.role == SyncGroupRole.primary
          ? SyncAuthorityEngine(
              SyncAuthorityStore(await repository.openSharedDatabase()),
              primaryDeviceId: controller.preferences.deviceId,
            )
          : null;
      final peer = IrohSyncGroupPeer(
        bridge: bridge,
        endpointSecret: endpointSecret,
        authority: authority,
      );
      return GroupSyncTransport(
        peer: peer,
        profile: profile,
        deviceId: controller.preferences.deviceId,
        endpointId: actualEndpointId,
        displayName: controller.preferences.deviceName,
        deviceIdProvider: () => controller.preferences.deviceId,
        endpointIdProvider: () => actualEndpointId,
        displayNameProvider: () => controller.preferences.deviceName,
      );
    },
  );
  final syncCoordinator = SyncCoordinator(
    repository: repository,
    transport: syncTransport,
    tokenStore: SecureSyncTokenStore(),
    connectivityMonitor: PlatformConnectivityMonitor(),
    deviceId: config.deviceId,
    retryLimit: config.syncRetryLimit,
    platformLifecycle: const MethodChannelSyncPlatformLifecycle(),
  );
  syncCoordinator.addListener(() {
    if (syncCoordinator.snapshot.localDataChanged &&
        cycleController.initialized) {
      unawaited(cycleController.refresh().catchError((_) {}));
    }
  });
  controller = ItemController(
    repository: repository,
    config: config,
    syncCoordinator: syncCoordinator,
    syncGroupSetup: syncGroupSetup,
    widgetCycleStatesProvider: () {
      final today = cycleDate(configuredNow());
      return cycleController.statesBetween(
        today.subtract(const Duration(days: 14)),
        today.add(const Duration(days: 21)),
      );
    },
    widgetSnapshotWriter: const PlatformWidgetSnapshotWriter(),
    desktopWindowController: desktopWindowController,
    notificationService: notificationService,
  );
  cycleController.addListener(() {
    if (cycleController.initialized) {
      unawaited(controller.refreshWidgetSnapshot().catchError((_) {}));
    }
  });
  await controller.initialize();
  await cycleController.initialize();
  await controller.refreshWidgetSnapshot();
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
