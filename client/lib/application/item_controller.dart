import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:timezone/timezone.dart' as tz;

import '../ai/ai_key_store.dart';
import '../ai/ai_provider.dart';
import '../ai/ai_provider_connection_tester.dart';
import '../config/app_config.dart';
import '../data/item_repository.dart';
import '../data/local_ics_service.dart';
import '../data/service_probe_client.dart';
import '../data/subscription_fetch_client.dart';
import '../data/transfer_models.dart';
import '../device/device_identity.dart';
import '../domain/item.dart';
import '../domain/subscription.dart';
import '../notification/notification_service.dart';
import '../sync/sync_coordinator.dart';
import '../sync/sync_models.dart';
import '../sync/token_store.dart';
import '../utils/configured_time.dart';
import '../widget/widget_snapshot_writer.dart';
import '../window/desktop_window_controller.dart';

class ItemController extends ChangeNotifier {
  ItemController({
    required this.repository,
    required this.config,
    this.syncCoordinator,
    this.widgetSnapshotWriter,
    this.desktopWindowController,
    this.notificationService,
    AiApiKeyStore? aiApiKeyStore,
    AiProviderConnectionTester? aiProviderConnectionTester,
    DeviceIdentity? deviceIdentity,
    SyncTokenStore? featureTokenStore,
    ServiceProbeClient? serviceProbeClient,
    SubscriptionFetchClient? subscriptionFetchClient,
  }) {
    syncCoordinator?.addListener(_syncChanged);
    _aiApiKeyStore = aiApiKeyStore ?? SecureAiApiKeyStore();
    _aiProviderConnectionTester =
        aiProviderConnectionTester ?? AiProviderConnectionTester();
    _deviceIdentity = deviceIdentity ?? DeviceIdentity();
    this.featureTokenStore = featureTokenStore ?? SecureFeatureTokenStore();
    _serviceProbeClient = serviceProbeClient ?? ServiceProbeClient();
    _subscriptionFetchClient =
        subscriptionFetchClient ?? SubscriptionFetchClient();
  }

  final ItemRepository repository;
  final AppConfig config;
  final SyncCoordinator? syncCoordinator;
  final WidgetSnapshotWriter? widgetSnapshotWriter;
  final DesktopWindowController? desktopWindowController;
  final NotificationService? notificationService;
  late final AiApiKeyStore _aiApiKeyStore;
  late final AiProviderConnectionTester _aiProviderConnectionTester;
  late final DeviceIdentity _deviceIdentity;
  late final SyncTokenStore featureTokenStore;
  late final ServiceProbeClient _serviceProbeClient;
  late final SubscriptionFetchClient _subscriptionFetchClient;
  final LocalIcsService _localIcsService = const LocalIcsService();

  List<CalendarItem> _items = const [];
  List<CalendarCollection> _collections = const [];
  ClientPreferences? _preferences;
  bool _loading = true;
  bool _initialized = false;
  bool _mutating = false;
  Object? _error;
  bool _featureTokenConfigured = false;
  ServiceProbeResult? _syncServiceProbe;
  ServiceProbeResult? _featureServiceProbe;

  List<CalendarItem> get items => List.unmodifiable(_items);
  List<CalendarCollection> get collections => List.unmodifiable(_collections);
  ClientPreferences get preferences => _preferences ?? _defaultPreferences;
  bool get loading => _loading;
  bool get initialized => _initialized;
  bool get mutating => _mutating;
  Object? get error => _error;
  String? get databasePath => repository.databasePath;
  bool get featureTokenConfigured => _featureTokenConfigured;
  ServiceProbeResult? get syncServiceProbe => _syncServiceProbe;
  ServiceProbeResult? get featureServiceProbe => _featureServiceProbe;
  String get activeTimezone => _resolveTimezone(preferences);

  ClientPreferences get _defaultPreferences => ClientPreferences(
    apiUrl: config.apiUrl,
    featureApiUrl: config.featureApiUrl,
    timezone: config.timezonePreference ?? config.timezone,
    localeName: config.localePreference ?? config.locale.toLanguageTag(),
    deviceId: config.deviceId,
    defaultCollectionId: config.defaultCollectionId,
    defaultCollectionName: config.defaultCollectionName,
    syncEnabled: config.syncEnabled,
    notificationsEnabled: config.notificationsEnabled,
    windowOpacity: 1,
    windowAlwaysOnTop: false,
    tagColors: const {},
  );

  List<AiProviderConfig> get aiProviders => preferences.aiProviders;

  Future<List<AiProviderConfig>> refreshAiProviderKeyStatus() async {
    final providers = preferences.aiProviders;
    final refreshed = <AiProviderConfig>[];
    for (final provider in providers) {
      bool configured = false;
      try {
        configured =
            (await _aiApiKeyStore.read(provider.id))?.isNotEmpty == true;
      } catch (_) {
        // Secure storage is optional while running on unsupported test targets.
      }
      refreshed.add(provider.copyWith(keyConfigured: configured));
    }
    if (!_sameProviders(refreshed, preferences.aiProviders)) {
      _preferences = preferences.copyWith(aiProviders: refreshed);
      notifyListeners();
    }
    return List.unmodifiable(refreshed);
  }

  Future<void> saveAiProvider(
    AiProviderConfig provider, {
    String? apiKey,
  }) async {
    final providers = [...preferences.aiProviders];
    final index = providers.indexWhere((value) => value.id == provider.id);
    final stored = provider.copyWith(
      keyConfigured: apiKey?.trim().isNotEmpty == true
          ? true
          : provider.keyConfigured,
    );
    if (index < 0) {
      providers.add(stored);
    } else {
      providers[index] = stored;
    }
    if (apiKey?.trim().isNotEmpty == true) {
      await _aiApiKeyStore.write(provider.id, apiKey!.trim());
    }
    await savePreferences(
      preferences.copyWith(assistantEnabled: true, aiProviders: providers),
    );
  }

  Future<void> deleteAiProvider(String providerId) async {
    await _aiApiKeyStore.clear(providerId);
    await savePreferences(
      preferences.copyWith(
        aiProviders: preferences.aiProviders
            .where((provider) => provider.id != providerId)
            .toList(growable: false),
      ),
    );
  }

  Future<void> clearAiProviderKey(String providerId) async {
    await _aiApiKeyStore.clear(providerId);
    final providers = preferences.aiProviders
        .map(
          (provider) => provider.id == providerId
              ? provider.copyWith(keyConfigured: false)
              : provider,
        )
        .toList(growable: false);
    _preferences = preferences.copyWith(aiProviders: providers);
    notifyListeners();
  }

  Future<void> testAiProvider(
    AiProviderConfig provider, {
    String pendingApiKey = '',
  }) async {
    String? key = pendingApiKey.trim();
    if (key.isEmpty) {
      try {
        key = await _aiApiKeyStore.read(provider.id);
      } catch (_) {
        // Connection testing can still validate local Ollama endpoints without a key.
      }
    }
    await _aiProviderConnectionTester.test(provider, apiKey: key);
  }

  Future<List<String>> discoverAiModels(
    AiProviderConfig provider, {
    String pendingApiKey = '',
  }) async {
    String? key = pendingApiKey.trim();
    if (key.isEmpty) {
      try {
        key = await _aiApiKeyStore.read(provider.id);
      } catch (_) {
        // Local Ollama discovery and keyless endpoints remain usable.
      }
    }
    return _aiProviderConnectionTester.discoverModels(provider, apiKey: key);
  }

  List<CalendarItem> get todayItems {
    final now = configuredNow();
    return _items
        .where((item) {
          final value = item.scheduleAt;
          if (value == null || item.status == ItemStatus.cancelled) {
            return false;
          }
          final scheduled = inConfiguredTimezone(value);
          return scheduled.year == now.year &&
              scheduled.month == now.month &&
              scheduled.day == now.day;
        })
        .toList(growable: false);
  }

  List<CalendarItem> get dueItems => _items
      .where((item) => item.type == ItemType.task && item.dueAt != null)
      .toList(growable: false);

  Future<void> initialize() async {
    _loading = true;
    notifyListeners();
    try {
      await repository.initialize();
      _initialized = true;
      try {
        _featureTokenConfigured =
            (await featureTokenStore.read())?.isNotEmpty == true;
      } catch (_) {
        _featureTokenConfigured = false;
      }
      final loadedPreferences = await repository.loadPreferences(
        _defaultPreferences,
      );
      final deviceId = _deviceIdentity.ensurePersistedId(
        loadedPreferences.deviceId,
        fallbackId: config.deviceId,
      );
      final deviceName = _deviceIdentity.ensureDeviceName(
        loadedPreferences.deviceName,
        deviceId: deviceId,
      );
      _preferences = loadedPreferences.copyWith(
        deviceId: deviceId,
        deviceName: deviceName,
      );
      if (deviceId != loadedPreferences.deviceId ||
          deviceName != loadedPreferences.deviceName) {
        await repository.savePreferences(_preferences!);
      }
      await _applyRuntimeSettings(_preferences!);
      try {
        await desktopWindowController?.initialize(
          opacity: _preferences!.windowOpacity,
          alwaysOnTop: _preferences!.windowAlwaysOnTop,
        );
      } catch (_) {
        // Window preferences are optional and must not block local startup.
      }
      await syncCoordinator?.start(
        enabled: _preferences!.syncEnabled,
        serverUrl: _preferences!.apiUrl,
      );
      await _reload(notify: false);
      _error = null;
    } catch (caught) {
      _initialized = false;
      _error = caught;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> refresh() => _reload();

  Future<CalendarItem?> saveItem({
    CalendarItem? current,
    required ItemDraft draft,
  }) async {
    CalendarItem? result;
    await _mutate(() async {
      result = current == null
          ? await repository.createItem(draft)
          : await repository.updateItem(current, draft);
    });
    return result;
  }

  Future<CalendarCollection> createCollection({
    required String name,
    required int color,
  }) async {
    late CalendarCollection result;
    await _mutate(
      () async =>
          result = await repository.createCollection(name: name, color: color),
      reloadItems: false,
    );
    _collections = await repository.listCollections();
    notifyListeners();
    return result;
  }

  Future<CalendarCollection> updateCollection(
    CalendarCollection current, {
    required String name,
    required int color,
  }) async {
    late CalendarCollection result;
    await _mutate(
      () async => result = await repository.updateCollection(
        current,
        name: name,
        color: color,
      ),
      reloadItems: false,
    );
    _collections = await repository.listCollections();
    notifyListeners();
    return result;
  }

  Future<void> deleteCollection(CalendarCollection current) async {
    await _mutate(
      () => repository.deleteCollection(current),
      reloadItems: false,
    );
    _collections = await repository.listCollections();
    notifyListeners();
  }

  Future<void> deleteItem(CalendarItem item) =>
      _mutate(() => repository.deleteItem(item));

  Future<CalendarItem> restoreItem(CalendarItem item) async {
    late CalendarItem result;
    await _mutate(() async {
      result = await repository.restoreItem(item);
    });
    return result;
  }

  Future<List<CalendarItem>> listDeletedItems() =>
      repository.listDeletedItems();

  Future<String> exportLocalJsonBackup() => repository.exportLocalJsonBackup();

  Future<TransferResult> previewLocalJsonImport(String content) =>
      repository.previewLocalJsonImport(content);

  Future<void> commitLocalJsonImport(String content) async {
    await _mutate(() => repository.commitLocalJsonImport(content));
  }

  Future<String> exportLocalIcs() async => _localIcsService.export(_items);

  Future<TransferResult> previewLocalIcsImport(String content) async =>
      _localIcsService
          .planImport(
            content,
            defaultTimezone: activeTimezone,
            existingItems: _items,
          )
          .result;

  Future<void> commitLocalIcsImport(String content) async {
    await _mutate(() async {
      final plan = _localIcsService.planImport(
        content,
        defaultTimezone: activeTimezone,
        existingItems: _items,
      );
      if (!plan.result.accepted) {
        throw FormatException(
          'ICS 文件包含 ${plan.result.issues.length} 个问题，请修正后重试。',
        );
      }
      for (final draft in plan.drafts) {
        await repository.createItem(draft);
      }
    });
  }

  Future<List<CalendarSubscription>> listSubscriptions() =>
      repository.listSubscriptions();

  Future<CalendarSubscription> createSubscription({
    required String title,
    required String url,
    required int refreshIntervalMinutes,
  }) async {
    late CalendarSubscription result;
    await _mutate(() async {
      result = await repository.createSubscription(
        title: title,
        url: url,
        refreshIntervalMinutes: refreshIntervalMinutes,
      );
    });
    return result;
  }

  Future<CalendarSubscription> updateSubscription(
    CalendarSubscription current, {
    required String title,
    required String url,
    required bool enabled,
    required int refreshIntervalMinutes,
  }) async {
    late CalendarSubscription result;
    await _mutate(() async {
      result = await repository.updateSubscription(
        current,
        title: title,
        url: url,
        enabled: enabled,
        refreshIntervalMinutes: refreshIntervalMinutes,
      );
    });
    return result;
  }

  Future<void> deleteSubscription(CalendarSubscription current) =>
      _mutate(() => repository.deleteSubscription(current));

  Future<SubscriptionFetchLog> refreshSubscription(
    CalendarSubscription current,
  ) async {
    final fetchedAt = DateTime.now();
    try {
      final response = await _subscriptionFetchClient.fetch(current);
      var events = const <LocalIcsEvent>[];
      if (!response.notModified) {
        final plan = _localIcsService.planImport(
          response.content,
          defaultTimezone: activeTimezone,
          deduplicate: false,
        );
        if (!plan.result.accepted) {
          throw FormatException('订阅文件包含 ${plan.result.issues.length} 个无效日程。');
        }
        events = plan.events;
      }
      late SubscriptionFetchLog result;
      await _mutate(() async {
        result = await repository.applySubscriptionRefresh(
          current,
          events: events,
          notModified: response.notModified,
          httpStatus: response.statusCode,
          fetchedAt: fetchedAt,
          etag: response.etag,
          lastModified: response.lastModified,
          sourceHash: response.sourceHash,
        );
      });
      return result;
    } catch (error) {
      try {
        await _mutate(
          () => repository.recordSubscriptionRefreshFailure(
            current,
            fetchedAt: fetchedAt,
            error: '$error',
            httpStatus: error is SubscriptionFetchException
                ? error.statusCode
                : null,
          ),
          reloadItems: false,
        );
      } catch (_) {
        // Preserve the original fetch or parse error if failure logging races.
      }
      rethrow;
    }
  }

  Future<List<SubscriptionFetchLog>> listSubscriptionFetchLogs(
    String subscriptionId,
  ) => repository.listSubscriptionFetchLogs(subscriptionId);

  Future<void> setTaskCompleted(CalendarItem item, {required bool completed}) =>
      _mutate(() async {
        await repository.setTaskCompleted(item, completed: completed);
      });

  Future<void> savePreferences(ClientPreferences value) async {
    try {
      tz.getLocation(_resolveTimezone(value));
    } catch (_) {
      throw FormatException('无法识别时区：${value.timezone}');
    }
    await _mutate(() async {
      await repository.savePreferences(value);
      if (preferences.apiUrl != value.apiUrl) _syncServiceProbe = null;
      if (preferences.featureApiUrl != value.featureApiUrl) {
        _featureServiceProbe = null;
      }
      _preferences = value;
      await _applyRuntimeSettings(value);
      try {
        await desktopWindowController?.setOpacity(value.windowOpacity);
        await desktopWindowController?.setAlwaysOnTop(value.windowAlwaysOnTop);
      } catch (_) {
        // A platform window adapter may be unavailable while the app is starting.
      }
      syncCoordinator?.configure(
        enabled: value.syncEnabled,
        serverUrl: value.apiUrl,
      );
      if (value.syncEnabled) unawaited(syncCoordinator?.synchronize());
    }, reloadItems: false);
  }

  Future<ClientPreferences> regenerateDeviceIdentity() async {
    final updated = preferences.copyWith(
      deviceId: _deviceIdentity.generateDistinctId(preferences.deviceId),
    );
    await savePreferences(updated);
    return updated;
  }

  Future<void> _applyRuntimeSettings(ClientPreferences value) async {
    syncCoordinator?.configureDeviceId(value.deviceId);
    if (repository is RuntimeSettingsPort) {
      await (repository as RuntimeSettingsPort).configureRuntime(
        deviceId: value.deviceId,
        defaultCollectionId: value.defaultCollectionId,
        defaultCollectionName: value.defaultCollectionName,
      );
    }
    try {
      tz.setLocalLocation(tz.getLocation(_resolveTimezone(value)));
    } catch (_) {
      throw FormatException('无法识别时区：${value.timezone}');
    }
  }

  String _resolveTimezone(ClientPreferences value) =>
      value.timezone == 'system' ? config.timezone : value.timezone;

  Future<void> _mutate(
    Future<void> Function() operation, {
    bool reloadItems = true,
  }) async {
    if (_mutating) {
      throw const RepositoryConflict('另一个本地操作正在进行。');
    }
    _mutating = true;
    _error = null;
    notifyListeners();
    try {
      await operation();
      if (reloadItems) await _reload(notify: false);
      if (reloadItems && preferences.syncEnabled) {
        unawaited(syncCoordinator?.synchronize());
      }
    } catch (caught) {
      _error = caught;
      rethrow;
    } finally {
      _mutating = false;
      notifyListeners();
    }
  }

  Future<void> _reload({bool notify = true}) async {
    _items = await repository.listItems();
    _collections = await repository.listCollections();
    try {
      await widgetSnapshotWriter?.write(
        items: _items,
        timezone: activeTimezone,
      );
    } catch (_) {
      // Widget refresh is derived state and must not block local CRUD.
    }
    if (preferences.notificationsEnabled) {
      unawaited(notificationService?.reconcileAll(_items));
    }
    if (notify) notifyListeners();
  }

  Future<void> saveSyncToken(String token) async {
    await syncCoordinator?.saveToken(token);
    _syncServiceProbe = null;
    notifyListeners();
  }

  Future<void> clearSyncToken() async {
    await syncCoordinator?.clearToken();
    _syncServiceProbe = null;
    notifyListeners();
  }

  Future<void> saveFeatureToken(String token) async {
    final normalized = token.trim();
    if (normalized.isEmpty) return;
    await featureTokenStore.write(normalized);
    _featureTokenConfigured = true;
    _featureServiceProbe = null;
    notifyListeners();
  }

  Future<void> clearFeatureToken() async {
    await featureTokenStore.clear();
    _featureTokenConfigured = false;
    _featureServiceProbe = null;
    notifyListeners();
  }

  Future<ServiceProbeResult> testServiceConnection({
    required ServiceKind kind,
    required String serverUrl,
    String pendingToken = '',
  }) async {
    var token = pendingToken.trim();
    if (token.isEmpty) {
      final store = kind == ServiceKind.sync
          ? syncCoordinator?.tokenStore
          : featureTokenStore;
      try {
        token = (await store?.read())?.trim() ?? '';
      } catch (_) {
        token = '';
      }
    }
    final result = await _serviceProbeClient.probe(
      serverUrl: Uri.parse(serverUrl.trim()),
      kind: kind,
      token: token,
    );
    if (kind == ServiceKind.sync) {
      _syncServiceProbe = result;
    } else {
      _featureServiceProbe = result;
    }
    notifyListeners();
    return result;
  }

  Future<void> synchronizeNow() async {
    await syncCoordinator?.synchronize();
    await _reload();
  }

  Future<List<SyncConflictRecord>> loadSyncConflictHistory() async =>
      syncCoordinator?.loadConflictHistory() ?? const [];

  void _syncChanged() {
    if (syncCoordinator?.snapshot.phase == SyncPhase.idle &&
        _initialized &&
        !_mutating) {
      unawaited(_reload());
    } else {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    syncCoordinator?.removeListener(_syncChanged);
    syncCoordinator?.dispose();
    unawaited(repository.close());
    _aiProviderConnectionTester.close();
    _serviceProbeClient.close();
    _subscriptionFetchClient.close();
    super.dispose();
  }

  static bool _sameProviders(
    List<AiProviderConfig> left,
    List<AiProviderConfig> right,
  ) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index].keyConfigured != right[index].keyConfigured) return false;
    }
    return true;
  }
}
