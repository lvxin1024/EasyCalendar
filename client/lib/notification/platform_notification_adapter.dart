import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:url_launcher/url_launcher.dart';

import 'notification_adapter.dart';

class PlatformNotificationAdapter implements NotificationAdapter {
  PlatformNotificationAdapter({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'easycalendar_reminders',
      '日程提醒',
      channelDescription: 'EasyCalendar 的日程和待办提醒',
      importance: Importance.high,
      priority: Priority.high,
    ),
    iOS: DarwinNotificationDetails(presentAlert: true, presentSound: true),
    macOS: DarwinNotificationDetails(presentAlert: true, presentSound: true),
    windows: WindowsNotificationDetails(),
  );

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;

  @override
  String get platformName {
    if (kIsWeb) return 'web';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    return 'unsupported';
  }

  Future<void> _initialize() async {
    if (_initialized) return;
    if (!const {'android', 'ios', 'macos', 'windows'}.contains(platformName)) {
      throw UnsupportedError('当前平台不支持系统通知');
    }
    final initialized = await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
        macOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
        windows: WindowsInitializationSettings(
          appName: 'EasyCalendar',
          appUserModelId: 'io.easycalendar.EasyCalendar',
          guid: '7d420780-1f73-4b91-8726-f67e4d2513ab',
        ),
      ),
    );
    if (initialized == false) {
      throw StateError('系统通知初始化失败');
    }
    _initialized = true;
  }

  @override
  Future<NotificationPermissionStatus> checkPermission() async {
    await _initialize();
    if (Platform.isWindows) return NotificationPermissionStatus.granted;
    if (Platform.isAndroid) {
      final implementation = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      final enabled = await implementation?.areNotificationsEnabled();
      return enabled == true
          ? NotificationPermissionStatus.granted
          : NotificationPermissionStatus.denied;
    }
    if (Platform.isIOS) {
      final implementation = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      final permissions = await implementation?.checkPermissions();
      if (permissions == null) {
        return NotificationPermissionStatus.notDetermined;
      }
      return permissions.isEnabled
          ? NotificationPermissionStatus.granted
          : NotificationPermissionStatus.denied;
    }
    final implementation = _plugin
        .resolvePlatformSpecificImplementation<
          MacOSFlutterLocalNotificationsPlugin
        >();
    final permissions = await implementation?.checkPermissions();
    if (permissions == null) return NotificationPermissionStatus.notDetermined;
    return permissions.isEnabled
        ? NotificationPermissionStatus.granted
        : NotificationPermissionStatus.denied;
  }

  @override
  Future<NotificationPermissionStatus> requestPermission() async {
    await _initialize();
    if (Platform.isWindows) return NotificationPermissionStatus.granted;
    final granted = Platform.isAndroid
        ? await _plugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.requestNotificationsPermission()
        : Platform.isIOS
        ? await _plugin
              .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin
              >()
              ?.requestPermissions(alert: true, sound: true)
        : await _plugin
              .resolvePlatformSpecificImplementation<
                MacOSFlutterLocalNotificationsPlugin
              >()
              ?.requestPermissions(alert: true, sound: true);
    return granted == true
        ? NotificationPermissionStatus.granted
        : NotificationPermissionStatus.denied;
  }

  @override
  Future<String> schedule(NotificationRequest request) async {
    await _initialize();
    final id = _stableId(request.notificationId);
    tz.Location location;
    try {
      location = tz.getLocation(request.timezoneName ?? '');
    } catch (_) {
      location = tz.local;
    }
    await _plugin.zonedSchedule(
      id: id,
      title: request.title,
      body: request.body,
      scheduledDate: tz.TZDateTime.from(request.fireAt, location),
      notificationDetails: _details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: request.itemId,
    );
    return 'system:$id:${request.itemId}';
  }

  @override
  Future<void> show(NotificationRequest request) async {
    await _initialize();
    await _plugin.show(
      id: _stableId(request.notificationId),
      title: request.title,
      body: request.body,
      notificationDetails: _details,
      payload: request.itemId,
    );
  }

  @override
  Future<void> cancel(String platformScheduleId) async {
    await _initialize();
    final parts = platformScheduleId.split(':');
    final id = parts.length >= 2 ? int.tryParse(parts[1]) : null;
    if (id != null) await _plugin.cancel(id: id);
  }

  @override
  Future<void> cancelAll() async {
    await _initialize();
    await _plugin.cancelAll();
  }

  @override
  Future<List<String>> pendingIds() async {
    await _initialize();
    final pending = await _plugin.pendingNotificationRequests();
    return pending
        .map((request) => 'system:${request.id}:${request.payload ?? ''}')
        .toList(growable: false);
  }

  @override
  Future<bool> openSettings() async {
    final uri = switch (platformName) {
      'android' => Uri.parse('app-settings:'),
      'ios' => Uri.parse('app-settings:'),
      'macos' => Uri.parse(
        'x-apple.systempreferences:com.apple.preference.notifications',
      ),
      'windows' => Uri.parse('ms-settings:notifications'),
      _ => null,
    };
    if (uri == null) return false;
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  static int _stableId(String value) {
    final bytes = sha256.convert(value.codeUnits).bytes;
    return ((bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]) &
        0x7FFFFFFF;
  }
}
