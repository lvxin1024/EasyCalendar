import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/item.dart';
import 'notification_adapter.dart';

class NotificationService extends ChangeNotifier {
  NotificationService({required this.adapter});

  final NotificationAdapter adapter;
  NotificationPermissionStatus _permission =
      NotificationPermissionStatus.notDetermined;
  bool _initialized = false;
  String? _unavailableReason;
  String? _lastScheduleError;

  NotificationPermissionStatus get permission => _permission;
  bool get initialized => _initialized;
  bool get available => _permission == NotificationPermissionStatus.granted;
  String? get unavailableReason => _unavailableReason;
  String? get lastScheduleError => _lastScheduleError;

  Future<void> initialize() async {
    if (_initialized) return;
    try {
      _permission = await adapter.checkPermission();
      _unavailableReason = null;
    } catch (error) {
      _permission = NotificationPermissionStatus.unavailable;
      _unavailableReason = error.toString();
    }
    _initialized = true;
    notifyListeners();
  }

  Future<void> reconcileItem(CalendarItem item) async {
    if (!_initialized || !available) return;
    try {
      final existingIds = await adapter.pendingIds();
      for (final id in existingIds) {
        if (id.contains(item.id)) {
          await adapter.cancel(id);
        }
      }
      if (item.isDeleted || item.status == ItemStatus.cancelled) return;
      if (!item.reminderEnabled) return;

      final scheduleAt = item.type == ItemType.event
          ? item.startAt
          : item.dueAt;
      if (scheduleAt == null) return;

      final fireAt = scheduleAt.subtract(
        Duration(minutes: item.reminderMinutes),
      );
      if (fireAt.isBefore(DateTime.now())) return;

      await adapter.schedule(
        NotificationRequest(
          notificationId: '${item.id}:reminder:0',
          itemId: item.id,
          title: item.title,
          body: item.body,
          fireAt: fireAt,
          timezoneName: item.timezone,
        ),
      );
      _lastScheduleError = null;
    } catch (error) {
      _lastScheduleError = error.toString();
      notifyListeners();
    }
  }

  Future<void> reconcileAll(List<CalendarItem> items) async {
    if (!_initialized || !available) return;
    try {
      await adapter.cancelAll();
    } catch (error) {
      _lastScheduleError = error.toString();
      notifyListeners();
      return;
    }
    for (final item in items) {
      await reconcileItem(item);
    }
  }

  Future<void> refreshPermission() async {
    if (!_initialized) return;
    try {
      _permission = await adapter.checkPermission();
      _unavailableReason = null;
    } catch (error) {
      _permission = NotificationPermissionStatus.unavailable;
      _unavailableReason = error.toString();
    }
    notifyListeners();
  }

  Future<NotificationPermissionStatus> requestPermission() async {
    if (!_initialized) await initialize();
    try {
      _permission = await adapter.requestPermission();
      _unavailableReason = null;
    } catch (error) {
      _permission = NotificationPermissionStatus.unavailable;
      _unavailableReason = error.toString();
    }
    notifyListeners();
    return _permission;
  }

  Future<void> showTestNotification() async {
    if (!_initialized) await initialize();
    if (!available) throw StateError('通知权限尚未授予');
    await adapter.show(
      NotificationRequest(
        notificationId: 'easycalendar:test',
        itemId: 'test',
        title: 'EasyCalendar 测试通知',
        body: '系统通知已正确连接。',
        fireAt: DateTime.now(),
      ),
    );
  }

  Future<void> cancelAll() async {
    try {
      await adapter.cancelAll();
      _lastScheduleError = null;
    } catch (error) {
      _lastScheduleError = error.toString();
    }
    notifyListeners();
  }

  Future<bool> openSystemSettings() => adapter.openSettings();

  String get statusText {
    if (!_initialized) return '未初始化';
    return switch (_permission) {
      NotificationPermissionStatus.granted => '已授权',
      NotificationPermissionStatus.denied => '权限被拒绝',
      NotificationPermissionStatus.notDetermined => '未请求权限',
      NotificationPermissionStatus.unavailable =>
        '不可用${_unavailableReason != null ? '：$_unavailableReason' : ''}',
    };
  }
}
