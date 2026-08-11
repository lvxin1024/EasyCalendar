import 'package:easy_calendar/domain/item.dart';
import 'package:easy_calendar/domain/recurrence.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

void main() {
  setUpAll(() {
    tz_data.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));
  });

  test('expands a weekly rule inside the requested range', () {
    final item = _event(
      start: tz.TZDateTime(tz.local, 2026, 7, 27, 9),
      recurrence: const RecurrenceRule(rrule: 'FREQ=WEEKLY;BYDAY=MO'),
    );

    final occurrences = expandCalendarItems(
      [item],
      DateTime(2026, 8, 1),
      DateTime(2026, 8, 20),
    );

    expect(occurrences.map((item) => item.startAt!.day), [3, 10, 17]);
    expect(occurrences.every((item) => item.id == 'series'), isTrue);
  });

  test('respects count and exception dates', () {
    final item = _event(
      start: tz.TZDateTime(tz.local, 2026, 8, 1, 9),
      recurrence: const RecurrenceRule(
        rrule: 'FREQ=DAILY;COUNT=3',
        exdates: ['2026-08-02T09:00:00+08:00'],
      ),
    );

    final occurrences = expandCalendarItems(
      [item],
      DateTime(2026, 8, 1),
      DateTime(2026, 8, 10),
    );

    expect(occurrences.map((item) => item.startAt!.day), [1, 3]);
  });
}

CalendarItem _event({
  required DateTime start,
  required RecurrenceRule recurrence,
}) => CalendarItem(
  id: 'series',
  collectionId: 'collection_local',
  type: ItemType.event,
  title: '循环日程',
  startAt: start,
  endAt: start.add(const Duration(hours: 1)),
  recurrence: recurrence,
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
