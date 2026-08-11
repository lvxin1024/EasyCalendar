import 'package:easy_calendar/domain/item.dart';
import 'package:easy_calendar/features/calendar/calendar_time_grid.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

void main() {
  setUpAll(() {
    tz_data.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));
  });

  test('assigns overlapping events to separate columns', () {
    final placements = layoutTimedEvents([
      _event('first', 9, 0, 10, 30),
      _event('second', 9, 30, 11, 0),
      _event('third', 11, 0, 12, 0),
    ], DateTime(2026, 8, 12));

    expect(placements.map((value) => value.column), [0, 1, 0]);
    expect(placements.map((value) => value.columnCount), [2, 2, 1]);
  });

  test('clips an event that crosses midnight', () {
    final item = CalendarItem(
      id: 'cross-midnight',
      collectionId: 'collection_local',
      type: ItemType.event,
      title: 'cross-midnight',
      startAt: tz.TZDateTime(tz.local, 2026, 8, 11, 23, 30),
      endAt: tz.TZDateTime(tz.local, 2026, 8, 12, 1, 15),
      timezone: 'Asia/Shanghai',
      allDay: false,
      status: ItemStatus.todo,
      reminderEnabled: false,
      reminderMinutes: 30,
      tags: const [],
      createdAt: DateTime.utc(2026, 8, 1),
      updatedAt: DateTime.utc(2026, 8, 1),
      version: 1,
    );

    final placement = layoutTimedEvents([item], DateTime(2026, 8, 12)).single;

    expect(placement.startMinutes, 0);
    expect(placement.endMinutes, 75);
  });
}

CalendarItem _event(
  String id,
  int startHour,
  int startMinute,
  int endHour,
  int endMinute,
) => CalendarItem(
  id: id,
  collectionId: 'collection_local',
  type: ItemType.event,
  title: id,
  startAt: tz.TZDateTime(tz.local, 2026, 8, 12, startHour, startMinute),
  endAt: tz.TZDateTime(tz.local, 2026, 8, 12, endHour, endMinute),
  timezone: 'Asia/Shanghai',
  allDay: false,
  status: ItemStatus.todo,
  reminderEnabled: false,
  reminderMinutes: 30,
  tags: const [],
  createdAt: DateTime.utc(2026, 8, 1),
  updatedAt: DateTime.utc(2026, 8, 1),
  version: 1,
);
