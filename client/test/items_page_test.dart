import 'package:easy_calendar/domain/item.dart';
import 'package:easy_calendar/domain/recurrence.dart';
import 'package:easy_calendar/features/items/items_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

void main() {
  late tz.TZDateTime now;

  setUpAll(() {
    tz_data.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));
    now = tz.TZDateTime(tz.local, 2026, 8, 31, 15, 30);
  });

  group('all items visibility', () {
    test('hides a timed event after its end', () {
      final event = _event(
        startAt: tz.TZDateTime(tz.local, 2026, 8, 31, 13),
        endAt: tz.TZDateTime(tz.local, 2026, 8, 31, 15),
      );

      expect(isVisibleInAllItems(event, now), isFalse);
    });

    test('keeps an event that is still in progress', () {
      final event = _event(
        startAt: tz.TZDateTime(tz.local, 2026, 8, 31, 15),
        endAt: tz.TZDateTime(tz.local, 2026, 8, 31, 16),
      );

      expect(isVisibleInAllItems(event, now), isTrue);
    });

    test('keeps an all-day event until the next day', () {
      final event = _event(
        startAt: tz.TZDateTime(tz.local, 2026, 8, 31),
        allDay: true,
      );

      expect(isVisibleInAllItems(event, now), isTrue);
      expect(
        isVisibleInAllItems(event, tz.TZDateTime(tz.local, 2026, 9, 1)),
        isFalse,
      );
    });

    test('keeps recurring events whose original occurrence is past', () {
      final event = _event(
        startAt: tz.TZDateTime(tz.local, 2025, 9, 22, 9),
        endAt: tz.TZDateTime(tz.local, 2025, 9, 22, 11),
        recurrence: const RecurrenceRule(rrule: 'FREQ=WEEKLY;BYDAY=MO'),
      );

      expect(isVisibleInAllItems(event, now), isTrue);
    });

    test('does not filter tasks or notes by schedule time', () {
      expect(isVisibleInAllItems(_item(ItemType.task), now), isTrue);
      expect(isVisibleInAllItems(_item(ItemType.note), now), isTrue);
    });

    test('hides completed due tasks', () {
      final task = _item(ItemType.task, status: ItemStatus.done);

      expect(isVisibleInAllItems(task, now), isFalse);
    });
  });
}

CalendarItem _event({
  required DateTime startAt,
  DateTime? endAt,
  bool allDay = false,
  RecurrenceRule? recurrence,
}) => CalendarItem(
  id: 'event',
  collectionId: 'collection_local',
  type: ItemType.event,
  title: 'Event',
  startAt: startAt,
  endAt: endAt,
  recurrence: recurrence,
  timezone: 'Asia/Shanghai',
  allDay: allDay,
  status: ItemStatus.todo,
  reminderEnabled: false,
  reminderMinutes: 30,
  tags: const [],
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  version: 1,
);

CalendarItem _item(ItemType type, {ItemStatus status = ItemStatus.todo}) =>
    CalendarItem(
      id: type.name,
      collectionId: 'collection_local',
      type: type,
      title: type.name,
      dueAt: DateTime.utc(2025),
      timezone: 'Asia/Shanghai',
      allDay: false,
      status: status,
      reminderEnabled: false,
      reminderMinutes: 30,
      tags: const [],
      createdAt: DateTime.utc(2025),
      updatedAt: DateTime.utc(2025),
      version: 1,
    );
