import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../domain/item.dart';
import '../domain/recurrence.dart';
import '../utils/configured_time.dart';

abstract interface class WidgetSnapshotWriter {
  Future<void> write({
    required List<CalendarItem> items,
    required String timezone,
    required List<String> quotes,
  });
}

class PlatformWidgetSnapshotWriter implements WidgetSnapshotWriter {
  const PlatformWidgetSnapshotWriter();

  static const _channel = MethodChannel('io.easycalendar/widget');

  @override
  Future<void> write({
    required List<CalendarItem> items,
    required String timezone,
    required List<String> quotes,
  }) async {
    if (!Platform.isMacOS && !Platform.isAndroid) return;
    final payload = WidgetSnapshotBuilder.build(
      items,
      timezone: timezone,
      quotes: quotes,
    );
    await _channel.invokeMethod<void>('writeSnapshot', <String, dynamic>{
      'json': jsonEncode(payload),
    });
  }
}

class WidgetSnapshotBuilder {
  const WidgetSnapshotBuilder._();

  static Map<String, dynamic> build(
    List<CalendarItem> items, {
    required String timezone,
    List<String> quotes = defaultWidgetQuotes,
    DateTime? now,
  }) {
    final effectiveNow = now ?? configuredNow();
    final localNow = inConfiguredTimezone(effectiveNow);
    final todayStart = configuredDateTime(
      year: localNow.year,
      month: localNow.month,
      day: localNow.day,
    );
    final tomorrow = todayStart.add(const Duration(days: 1));
    final upcomingEnd = todayStart.add(const Duration(days: 8));
    final weekStart = todayStart.subtract(
      Duration(days: todayStart.weekday - DateTime.monday),
    );
    final weekEnd = weekStart.add(const Duration(days: 7));
    final calendarWindowEnd = weekEnd.add(const Duration(days: 7));
    final todayEvents = <CalendarItem>[];
    final upcomingEvents = <CalendarItem>[];
    final weekEvents = <CalendarItem>[];
    final dueItems = <CalendarItem>[];
    for (final item in items) {
      final schedule = item.scheduleAt;
      if (schedule == null) continue;
      final localSchedule = inConfiguredTimezone(schedule);
      if (item.type == ItemType.event && item.status != ItemStatus.cancelled) {
        if (!localSchedule.isBefore(weekStart) &&
            localSchedule.isBefore(weekEnd)) {
          weekEvents.add(item);
        }
        if (!localSchedule.isBefore(todayStart) &&
            localSchedule.isBefore(tomorrow)) {
          todayEvents.add(item);
        } else if (!localSchedule.isBefore(tomorrow) &&
            localSchedule.isBefore(upcomingEnd)) {
          upcomingEvents.add(item);
        }
      } else if (item.type == ItemType.task &&
          item.status != ItemStatus.done &&
          item.status != ItemStatus.cancelled) {
        dueItems.add(item);
      }
    }
    todayEvents.sort(_compareItems);
    upcomingEvents.sort(_compareItems);
    weekEvents.sort(_compareItems);
    final calendarEvents =
        expandCalendarItems(
              items.where(
                (item) =>
                    item.type == ItemType.event &&
                    item.status != ItemStatus.cancelled &&
                    !item.isDeleted,
              ),
              weekStart,
              calendarWindowEnd,
            )
            .where((item) {
              final startAt = item.startAt;
              if (startAt == null) return false;
              final localStart = inConfiguredTimezone(startAt);
              return !localStart.isBefore(weekStart) &&
                  localStart.isBefore(calendarWindowEnd);
            })
            .toList(growable: false);
    calendarEvents.sort(_compareItems);
    dueItems.sort(_compareItems);
    final included = <CalendarItem>[
      ...todayEvents,
      ...upcomingEvents,
      ...dueItems,
    ];
    return <String, dynamic>{
      'schema_version': 2,
      'generated_at': effectiveNow.toUtc().toIso8601String(),
      'timezone': timezone,
      'version': items.fold<int>(
        0,
        (max, item) => item.version > max ? item.version : max,
      ),
      'today_events': todayEvents.map(_serializeItem).toList(growable: false),
      'upcoming_events': upcomingEvents
          .map(_serializeItem)
          .toList(growable: false),
      'week_events': weekEvents.map(_serializeItem).toList(growable: false),
      'calendar_events': calendarEvents
          .map(_serializeOccurrence)
          .toList(growable: false),
      'due_items': dueItems.map(_serializeItem).toList(growable: false),
      'quotes': quotes
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .take(10)
          .toList(growable: false),
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

  static Map<String, dynamic> _serializeOccurrence(CalendarItem item) {
    final serialized = _serializeItem(item);
    serialized['source_id'] = item.id;
    serialized['id'] = '${item.id}@${item.startAt!.toUtc().toIso8601String()}';
    return serialized;
  }
}
