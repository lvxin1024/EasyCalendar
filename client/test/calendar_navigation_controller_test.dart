import 'package:easy_calendar/domain/item.dart';
import 'package:easy_calendar/features/calendar/calendar_navigation_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

void main() {
  setUpAll(() {
    tz_data.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));
  });

  test('switches ranges without losing the selected date', () {
    final navigation = CalendarNavigationController(
      selectedDate: DateTime(2026, 8, 12),
    );

    navigation.setMode(CalendarViewMode.week);
    expect(navigation.selectedDate, DateTime(2026, 8, 12));
    expect(navigation.rangeStart, DateTime(2026, 8, 10));
    expect(navigation.rangeEnd, DateTime(2026, 8, 17));

    navigation.next();
    expect(navigation.selectedDate, DateTime(2026, 8, 19));
    navigation.setMode(CalendarViewMode.month);
    expect(navigation.rangeStart, DateTime(2026, 8));
    expect(navigation.rangeEnd, DateTime(2026, 9));
  });

  test('month navigation clamps the selected day', () {
    final navigation = CalendarNavigationController(
      selectedDate: DateTime(2026, 3, 31),
      initialMode: CalendarViewMode.month,
    );

    navigation.previous();

    expect(navigation.selectedDate, DateTime(2026, 2, 28));
  });

  test('custom first day changes week and month ranges', () {
    final navigation = CalendarNavigationController(
      selectedDate: DateTime(2026, 8, 12),
      initialFirstDayOfWeek: DateTime.sunday,
    );

    navigation.setMode(CalendarViewMode.week);
    expect(navigation.rangeStart, DateTime(2026, 8, 9));
    expect(navigation.rangeEnd, DateTime(2026, 8, 16));
    expect(navigation.monthGridStart, DateTime(2026, 7, 26));
  });

  test(
    'range query includes overlapping events and excludes cancelled items',
    () {
      final navigation = CalendarNavigationController(
        selectedDate: DateTime(2026, 8, 12),
      );
      final events = navigation.eventsInRange([
        _event(
          id: 'overlap',
          start: DateTime.utc(2026, 8, 11, 15, 30),
          end: DateTime.utc(2026, 8, 11, 17),
        ),
        _event(
          id: 'outside',
          start: DateTime.utc(2026, 8, 12, 16),
          end: DateTime.utc(2026, 8, 12, 17),
        ),
        _event(
          id: 'cancelled',
          start: DateTime.utc(2026, 8, 12, 2),
          end: DateTime.utc(2026, 8, 12, 3),
          status: ItemStatus.cancelled,
        ),
      ]);

      expect(events.map((event) => event.id), ['overlap']);
    },
  );

  test('computes ISO week numbers across year boundaries', () {
    expect(isoWeekNumber(DateTime(2021, 1, 1)), 53);
    expect(isoWeekNumber(DateTime(2021, 1, 4)), 1);
  });
}

CalendarItem _event({
  required String id,
  required DateTime start,
  required DateTime end,
  ItemStatus status = ItemStatus.todo,
}) => CalendarItem(
  id: id,
  collectionId: 'collection_local',
  type: ItemType.event,
  title: id,
  startAt: start,
  endAt: end,
  timezone: 'Asia/Shanghai',
  allDay: false,
  status: status,
  reminderEnabled: false,
  reminderMinutes: 30,
  tags: const [],
  createdAt: DateTime.utc(2026, 8, 1),
  updatedAt: DateTime.utc(2026, 8, 1),
  version: 1,
);
