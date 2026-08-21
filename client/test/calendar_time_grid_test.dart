import 'package:easy_calendar/domain/item.dart';
import 'package:easy_calendar/features/calendar/calendar_time_grid.dart';
import 'package:flutter/foundation.dart';
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

  test('reserves the last thirty minutes before an unfinished due time', () {
    final due = CalendarItem(
      id: 'due',
      collectionId: 'collection_local',
      type: ItemType.task,
      title: 'due',
      dueAt: tz.TZDateTime(tz.local, 2026, 8, 12, 15, 0),
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

    final placement = layoutTimedEvents(
      const [],
      DateTime(2026, 8, 12),
      dueItems: [due],
    ).single;

    expect(placement.startMinutes, 14 * 60 + 30);
    expect(placement.endMinutes, 15 * 60);
  });

  test('snaps timeline taps to quarter hours', () {
    expect(snapTimelineMinutes(0, 72), 0);
    expect(snapTimelineMinutes(7 * 72 / 60, 72), 0);
    expect(snapTimelineMinutes(8 * 72 / 60, 72), 15);
    expect(snapTimelineMinutes(22 * 72 / 60, 72), 15);
    expect(snapTimelineMinutes(23 * 72 / 60, 72), 30);
    expect(snapTimelineMinutes(53 * 72 / 60, 72), 60);
    expect(snapTimelineMinutes(24 * 72, 72), 23 * 60);
  });

  test('keeps compact week columns on Android', () {
    expect(
      calendarDateColumnWidth(
        dateCount: 7,
        availableWidth: 1200,
        platform: TargetPlatform.android,
      ),
      72,
    );
  });

  test('fits week columns to macOS and Windows window width', () {
    for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
      expect(
        calendarDateColumnWidth(
          dateCount: 7,
          availableWidth: 1048,
          platform: platform,
        ),
        closeTo(1000 / 7, 0.001),
      );
    }
  });

  test('desktop week columns retain a usable minimum width', () {
    expect(
      calendarDateColumnWidth(
        dateCount: 7,
        availableWidth: 420,
        platform: TargetPlatform.macOS,
      ),
      72,
    );
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
