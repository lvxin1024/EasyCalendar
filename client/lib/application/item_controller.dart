import 'dart:async';

import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../data/item_repository.dart';
import '../domain/item.dart';
import '../sync/sync_coordinator.dart';
import '../sync/sync_models.dart';
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
  }) {
    syncCoordinator?.addListener(_syncChanged);
  }

  final ItemRepository repository;
  final AppConfig config;
  final SyncCoordinator? syncCoordinator;
  final WidgetSnapshotWriter? widgetSnapshotWriter;
  final DesktopWindowController? desktopWindowController;

  List<CalendarItem> _items = const [];
  ClientPreferences? _preferences;
  bool _loading = true;
  bool _initialized = false;
  bool _mutating = false;
  Object? _error;

  List<CalendarItem> get items => List.unmodifiable(_items);
  ClientPreferences get preferences => _preferences ?? _defaultPreferences;
  bool get loading => _loading;
  bool get initialized => _initialized;
  bool get mutating => _mutating;
  Object? get error => _error;
  String? get databasePath => repository.databasePath;

  ClientPreferences get _defaultPreferences => ClientPreferences(
    apiUrl: config.apiUrl,
    syncEnabled: config.syncEnabled,
    notificationsEnabled: config.notificationsEnabled,
    windowOpacity: 1,
    windowAlwaysOnTop: false,
  );

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
      _preferences = await repository.loadPreferences(_defaultPreferences);
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

  Future<void> deleteItem(CalendarItem item) =>
      _mutate(() => repository.deleteItem(item));

  Future<void> setTaskCompleted(CalendarItem item, {required bool completed}) =>
      _mutate(() async {
        await repository.setTaskCompleted(item, completed: completed);
      });

  Future<void> savePreferences(ClientPreferences value) async {
    await _mutate(() async {
      await repository.savePreferences(value);
      _preferences = value;
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
    try {
      await widgetSnapshotWriter?.write(
        items: _items,
        timezone: config.timezone,
      );
    } catch (_) {
      // Widget refresh is derived state and must not block local CRUD.
    }
    if (notify) notifyListeners();
  }

  Future<void> saveSyncToken(String token) async {
    await syncCoordinator?.saveToken(token);
  }

  Future<void> clearSyncToken() async {
    await syncCoordinator?.clearToken();
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
    super.dispose();
  }
}
