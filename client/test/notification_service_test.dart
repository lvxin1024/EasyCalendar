import 'package:easy_calendar/domain/item.dart';
import 'package:easy_calendar/notification/notification_adapter.dart';
import 'package:easy_calendar/notification/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'initialization reports permission without prompting automatically',
    () async {
      final adapter = _FakeNotificationAdapter(
        permission: NotificationPermissionStatus.notDetermined,
      );
      final service = NotificationService(adapter: adapter);

      await service.initialize();

      expect(service.permission, NotificationPermissionStatus.notDetermined);
      expect(adapter.permissionRequests, 0);
    },
  );

  test('denied permission never blocks reminder reconciliation', () async {
    final adapter = _FakeNotificationAdapter(
      permission: NotificationPermissionStatus.denied,
    );
    final service = NotificationService(adapter: adapter);
    await service.initialize();

    await service.reconcileAll([_item()]);

    expect(adapter.scheduled, isEmpty);
    expect(service.statusText, '权限被拒绝');
  });

  test(
    'reconciliation restores, updates, and cancels platform reminders',
    () async {
      final adapter = _FakeNotificationAdapter(
        permission: NotificationPermissionStatus.granted,
      );
      final service = NotificationService(adapter: adapter);
      await service.initialize();

      await service.reconcileAll([_item()]);
      expect(adapter.scheduled, hasLength(1));
      expect(adapter.scheduled.single.timezoneName, 'Asia/Shanghai');

      await service.reconcileItem(_item(title: '改期后的提醒'));
      expect(adapter.cancelled, isNotEmpty);
      expect(adapter.scheduled.single.title, '改期后的提醒');

      await service.reconcileItem(_item(status: ItemStatus.cancelled));
      expect(adapter.scheduled, isEmpty);

      await service.reconcileAll([_item()]);
      await service.cancelAll();
      expect(adapter.scheduled, isEmpty);
    },
  );

  test(
    'permission request and test notification are explicit actions',
    () async {
      final adapter = _FakeNotificationAdapter(
        permission: NotificationPermissionStatus.notDetermined,
        requestedPermission: NotificationPermissionStatus.granted,
      );
      final service = NotificationService(adapter: adapter);
      await service.initialize();

      expect(
        await service.requestPermission(),
        NotificationPermissionStatus.granted,
      );
      await service.showTestNotification();

      expect(adapter.permissionRequests, 1);
      expect(adapter.shown.single.title, 'EasyCalendar 测试通知');
    },
  );
}

CalendarItem _item({
  String title = '未来会议',
  ItemStatus status = ItemStatus.todo,
}) {
  final now = DateTime.now();
  return CalendarItem(
    id: 'item_reminder',
    collectionId: 'collection_local',
    type: ItemType.event,
    title: title,
    startAt: now.add(const Duration(hours: 2)),
    endAt: now.add(const Duration(hours: 3)),
    timezone: 'Asia/Shanghai',
    allDay: false,
    status: status,
    reminderEnabled: true,
    reminderMinutes: 30,
    tags: const [],
    createdAt: now,
    updatedAt: now,
    version: 1,
  );
}

class _FakeNotificationAdapter implements NotificationAdapter {
  _FakeNotificationAdapter({
    required this.permission,
    this.requestedPermission = NotificationPermissionStatus.denied,
  });

  NotificationPermissionStatus permission;
  final NotificationPermissionStatus requestedPermission;
  int permissionRequests = 0;
  final List<NotificationRequest> scheduled = [];
  final List<NotificationRequest> shown = [];
  final List<String> cancelled = [];

  @override
  String get platformName => 'test';

  @override
  Future<NotificationPermissionStatus> checkPermission() async => permission;

  @override
  Future<NotificationPermissionStatus> requestPermission() async {
    permissionRequests++;
    permission = requestedPermission;
    return permission;
  }

  @override
  Future<String> schedule(NotificationRequest request) async {
    scheduled.removeWhere((value) => value.itemId == request.itemId);
    scheduled.add(request);
    return 'test:${request.notificationId}:${request.itemId}';
  }

  @override
  Future<void> show(NotificationRequest request) async => shown.add(request);

  @override
  Future<void> cancel(String platformScheduleId) async {
    cancelled.add(platformScheduleId);
    final itemId = platformScheduleId.split(':').last;
    scheduled.removeWhere((value) => value.itemId == itemId);
  }

  @override
  Future<void> cancelAll() async => scheduled.clear();

  @override
  Future<List<String>> pendingIds() async => scheduled
      .map((value) => 'test:${value.notificationId}:${value.itemId}')
      .toList(growable: false);

  @override
  Future<bool> openSettings() async => true;
}
