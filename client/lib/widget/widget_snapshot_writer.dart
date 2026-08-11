import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../domain/item.dart';
import '../utils/configured_time.dart';

abstract interface class WidgetSnapshotWriter {
  Future<void> write({
    required List<CalendarItem> items,
    required String timezone,
  });
}

class PlatformWidgetSnapshotWriter implements WidgetSnapshotWriter {
  const PlatformWidgetSnapshotWriter();

  static const _channel = MethodChannel('io.easycalendar/widget');

  @override
  Future<void> write({
    required List<CalendarItem> items,
    required String timezone,
  }) async {
    if (!Platform.isMacOS) return;
    final payload = _buildSnapshot(items, timezone: timezone);
    await _channel.invokeMethod<void>('writeSnapshot', <String, dynamic>{
      'json': jsonEncode(payload),
    });
  }

  Map<String, dynamic> _buildSnapshot(
    List<CalendarItem> items, {
    required String timezone,
  }) {
    final now = configuredNow();
    final todayStart = DateTime(now.year, now.month, now.day);
    final tomorrow = todayStart.add(const Duration(days: 1));
    final upcomingEnd = todayStart.add(const Duration(days: 8));
    final todayEvents = <CalendarItem>[];
    final upcomingEvents = <CalendarItem>[];
    final dueItems = <CalendarItem>[];
    for (final item in items) {
      final schedule = item.scheduleAt;
      if (schedule == null) continue;
      final localSchedule = inConfiguredTimezone(schedule);
      if (item.type == ItemType.event && item.status != ItemStatus.cancelled) {
        if (!localSchedule.isBefore(todayStart) &&
            localSchedule.isBefore(tomorrow)) {
          todayEvents.add(item);
        } else if (!localSchedule.isBefore(tomorrow) &&
            localSchedule.isBefore(upcomingEnd)) {
          upcomingEvents.add(item);
        }
      } else if (item.type == ItemType.task &&
          item.status != ItemStatus.done &&
          item.status != ItemStatus.cancelled &&
          localSchedule.isBefore(upcomingEnd)) {
        dueItems.add(item);
      }
    }
    todayEvents.sort(_compareItems);
    upcomingEvents.sort(_compareItems);
    dueItems.sort(_compareItems);
    final included = <CalendarItem>[
      ...todayEvents,
      ...upcomingEvents,
      ...dueItems,
    ];
    return <String, dynamic>{
      'schema_version': 1,
      'generated_at': now.toUtc().toIso8601String(),
      'timezone': timezone,
      'version': items.fold<int>(
        0,
        (max, item) => item.version > max ? item.version : max,
      ),
      'today_events': todayEvents.map(_serializeItem).toList(growable: false),
      'upcoming_events': upcomingEvents
          .map(_serializeItem)
          .toList(growable: false),
      'due_items': dueItems.map(_serializeItem).toList(growable: false),
      'items': included.map(_serializeItem).toList(growable: false),
    };
  }

  static int _compareItems(CalendarItem left, CalendarItem right) {
    final leftAt = left.scheduleAt;
    final rightAt = right.scheduleAt;
    if (leftAt == null && rightAt == null) return left.id.compareTo(right.id);
    if (leftAt == null) return 1;
    if (rightAt == null) return -1;
    final comparison = leftAt.compareTo(rightAt);
    return comparison == 0 ? left.id.compareTo(right.id) : comparison;
  }

  static Map<String, dynamic> _serializeItem(CalendarItem item) =>
      <String, dynamic>{
        'id': item.id,
        'type': item.type.name,
        'title': item.title,
        'start_at': item.startAt?.toUtc().toIso8601String(),
        'end_at': item.endAt?.toUtc().toIso8601String(),
        'due_at': item.dueAt?.toUtc().toIso8601String(),
        'timezone': item.timezone,
        'all_day': item.allDay,
        'location': item.location,
        'status': item.status.name,
        'priority': item.priority,
        'version': item.version,
      };
}
