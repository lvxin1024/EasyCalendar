import 'dart:async';
import 'dart:io';

import 'package:easy_calendar/application/cycle_controller.dart';
import 'package:easy_calendar/application/item_controller.dart';
import 'package:easy_calendar/config/app_config.dart';
import 'package:easy_calendar/data/local_cycle_repository.dart';
import 'package:easy_calendar/data/local_item_repository.dart';
import 'package:easy_calendar/domain/item.dart';
import 'package:easy_calendar/features/settings/settings_page.dart';
import 'package:easy_calendar/notification/notification_adapter.dart';
import 'package:easy_calendar/notification/notification_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/data/latest.dart' as tz_data;

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    tz_data.initializeTimeZones();
  });

  testWidgets(
    'notification preference survives restart and a failed toggle can be retried',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'easycalendar-notifications-',
      );
      final adapter = _PermissionAdapter();
      final service = NotificationService(adapter: adapter);
      LocalItemRepository createRepository() => LocalItemRepository(
        _config,
        databaseFactory: databaseFactoryFfi,
        databasePath: '${directory.path}/calendar.sqlite3',
      );
      var repository = createRepository();
      var controller = ItemController(
        repository: repository,
        config: _config,
        notificationService: service,
      );
      final cycleController = CycleController(
        repository: LocalCycleRepository(
          databaseProvider: () => repository.openSharedDatabase(),
        ),
      );
      addTearDown(() async {
        await repository.close();
        controller.dispose();
        cycleController.dispose();
        service.dispose();
        directory.deleteSync(recursive: true);
      });

      await tester.runAsync(() async {
        await controller.initialize();
        await cycleController.initialize();
        await service.initialize();
        await controller.saveItem(
          draft: ItemDraft(
            type: ItemType.event,
            title: '未来会议',
            startAt: DateTime.now().add(const Duration(days: 1)),
            endAt: DateTime.now().add(const Duration(days: 1, hours: 1)),
            timezone: 'Asia/Shanghai',
            reminderEnabled: true,
          ),
        );
      });
      expect(controller.error, isNull);

      final notificationToggle = find.widgetWithText(SwitchListTile, '通知');
      Future<void> showSettings() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SettingsPage(
                key: UniqueKey(),
                config: _config,
                controller: controller,
                cycleController: cycleController,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('提醒与通知'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          notificationToggle,
          400,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
      }

      Future<void> toggle() async {
        await tester.runAsync(() async {
          final completed = Completer<void>();
          void changed() {
            if (!controller.mutating && !completed.isCompleted) {
              completed.complete();
            }
          }

          controller.addListener(changed);
          try {
            await tester.tap(
              find.descendant(
                of: notificationToggle,
                matching: find.byType(Switch),
              ),
            );
            await completed.future.timeout(const Duration(seconds: 10));
          } finally {
            controller.removeListener(changed);
          }
        });
        await tester.pumpAndSettle();
      }

      await showSettings();
      expect(tester.widget<SwitchListTile>(notificationToggle).value, isFalse);
      await toggle();
      expect(tester.widget<SwitchListTile>(notificationToggle).value, isTrue);
      expect(service.permission, NotificationPermissionStatus.denied);
      expect(adapter.pendingRequests, isEmpty);
      await showSettings();
      expect(tester.widget<SwitchListTile>(notificationToggle).value, isTrue);

      // Reopen the database with a new controller to simulate application exit.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await repository.close();
        controller.dispose();
        repository = createRepository();
        controller = ItemController(
          repository: repository,
          config: _config,
          notificationService: service,
        );
        await controller.initialize();
      });
      await showSettings();
      expect(tester.widget<SwitchListTile>(notificationToggle).value, isTrue);

      // Granting system permission and refreshing restores reminders without
      // changing the saved notification preference.
      adapter.permission = NotificationPermissionStatus.granted;
      await tester.ensureVisible(find.byTooltip('刷新权限状态'));
      await tester.tap(find.byTooltip('刷新权限状态'));
      await tester.pumpAndSettle();
      expect(adapter.pendingRequests, hasLength(1));

      await showSettings();
      // A failed save must preserve the enabled preference and scheduled
      // reminders, report the error, and leave the switch available to retry.
      await tester.runAsync(repository.close);
      await toggle();
      expect(tester.widget<SwitchListTile>(notificationToggle).value, isTrue);
      expect(find.textContaining('保存通知设置失败'), findsOneWidget);
      expect(adapter.pendingRequests, hasLength(1));
      final afterFailure = await tester.runAsync(() async {
        await repository.initialize();
        return repository.loadPreferences(controller.preferences);
      });
      expect(afterFailure!.notificationsEnabled, isTrue);

      await toggle();
      expect(tester.widget<SwitchListTile>(notificationToggle).value, isFalse);
      expect(adapter.pendingRequests, isEmpty);
      final stored = await tester.runAsync(
        () => repository.loadPreferences(controller.preferences),
      );
      expect(stored!.notificationsEnabled, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}

class _PermissionAdapter extends InMemoryNotificationAdapter {
  NotificationPermissionStatus permission = NotificationPermissionStatus.denied;

  @override
  Future<NotificationPermissionStatus> checkPermission() async => permission;
}

const _config = AppConfig(
  appName: 'EasyCalendar',
  locale: Locale('zh', 'CN'),
  timezone: 'Asia/Shanghai',
  defaultCollectionId: 'collection_local',
  defaultCollectionName: '我的日程',
  defaultCollectionColor: Color(0xFF2563EB),
  databaseName: 'test.sqlite3',
  deviceId: 'test-device',
  apiUrl: 'http://localhost:8000',
  syncEnabled: false,
  syncRetryLimit: 8,
  notificationsEnabled: false,
);
