import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/item.dart';
import 'notification_adapter.dart';

class NotificationService extends ChangeNotifier {
  NotificationService({required this.adapter});

  final NotificationAdapter adapter;
  NotificationPermissionStatus _permission = NotificationPermissionStatus.notDetermined;
  bool _initialized = false;
  String? _unavailableReason;

  NotificationPermissionStatus get permission => _permission;
  bool get initialized => _initialized;
  bool get available => _permission == NotificationPermissionStatus.granted;
  String? get unavailableReason => _unavailableReason;

  Future<void> initialize() async {
    if (_initialized) return;
    try {
      _permission = await adapter.checkPermission();
      if (_permission == NotificationPermissionStatus.notDetermined) {
        _permission = await adapter.requestPermission();
      }
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
    // Cancel existing notifications for this item
    final existingIds = await adapter.pendingIds();
    for (final id in existingIds) {
      if (id.contains(item.id)) {
        await adapter.cancel(id);
      }
    }
    if (item.isDeleted || item.status == ItemStatus.cancelled) return;
    if (!item.reminderEnabled) return;

    final scheduleAt = item.type == ItemType.event ? item.startAt : item.dueAt;
    if (scheduleAt == null) return;

    final fireAt = scheduleAt.subtract(Duration(minutes: item.reminderMinutes));
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
  }

  Future<void> reconcileAll(List<CalendarItem> items) async {
    if (!_initialized || !available) return;
    await adapter.cancelAll();
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
