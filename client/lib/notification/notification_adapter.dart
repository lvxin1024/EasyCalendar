import 'package:flutter/foundation.dart';

class NotificationRequest {
  const NotificationRequest({
    required this.notificationId,
    required this.itemId,
    required this.title,
    this.body,
    required this.fireAt,
    this.timezoneName,
  });

  final String notificationId;
  final String itemId;
  final String title;
  final String? body;
  final DateTime fireAt;
  final String? timezoneName;
}

enum NotificationPermissionStatus {
  granted,
  denied,
  notDetermined,
  unavailable,
}

abstract interface class NotificationAdapter {
  String get platformName;

  Future<NotificationPermissionStatus> requestPermission();

  Future<NotificationPermissionStatus> checkPermission();

  Future<String> schedule(NotificationRequest request);

  Future<void> show(NotificationRequest request);

  Future<void> cancel(String platformScheduleId);

  Future<void> cancelAll();

  Future<List<String>> pendingIds();

  Future<bool> openSettings();
}

class InMemoryNotificationAdapter extends ChangeNotifier
    implements NotificationAdapter {
  final _scheduled = <String, NotificationRequest>{};

  @override
  String get platformName => 'memory';

  @override
  Future<NotificationPermissionStatus> requestPermission() async =>
      NotificationPermissionStatus.granted;

  @override
  Future<NotificationPermissionStatus> checkPermission() async =>
      NotificationPermissionStatus.granted;

  @override
  Future<String> schedule(NotificationRequest request) async {
    final id = 'memory:${request.notificationId}';
    _scheduled[id] = request;
    notifyListeners();
    return id;
  }

  @override
  Future<void> show(NotificationRequest request) async {}

  @override
  Future<void> cancel(String platformScheduleId) async {
    _scheduled.remove(platformScheduleId);
    notifyListeners();
  }

  @override
  Future<void> cancelAll() async {
    _scheduled.clear();
    notifyListeners();
  }

  @override
  Future<List<String>> pendingIds() async => _scheduled.keys.toList();

  @override
  Future<bool> openSettings() async => true;

  List<NotificationRequest> get pendingRequests =>
      List.unmodifiable(_scheduled.values);
}
