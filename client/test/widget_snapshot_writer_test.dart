import 'package:easy_calendar/domain/item.dart';
import 'package:easy_calendar/domain/recurrence.dart';
import 'package:easy_calendar/widget/widget_snapshot_writer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

void main() {
  setUpAll(() {
    tz_data.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));
  });

  test('snapshot keeps a Monday-to-Sunday event window for every platform', () {
    final snapshot = WidgetSnapshotBuilder.build(
      [
        _event('monday', 2026, 8, 17, 9),
        _event('sunday', 2026, 8, 23, 18),
        _event('next-week', 2026, 8, 24, 9),
        _event('cancelled', 2026, 8, 20, 9, status: ItemStatus.cancelled),
      ],
      timezone: 'Asia/Shanghai',
      now: tz.TZDateTime(tz.local, 2026, 8, 19, 12),
    );

    final week = snapshot['week_events']! as List<dynamic>;
    expect(week.map((value) => (value as Map<String, dynamic>)['id']), [
      'monday',
      'sunday',
    ]);
    final calendarWindow = snapshot['calendar_events']! as List<dynamic>;
    final calendarIds = calendarWindow
        .map((value) => (value as Map<String, dynamic>)['id'])
        .toList(growable: false);
    expect(calendarIds, contains(startsWith('monday@')));
    expect(calendarIds, contains(startsWith('sunday@')));
    expect(calendarIds, contains(startsWith('next-week@')));
    expect(snapshot['schema_version'], 1);
    expect(snapshot['timezone'], 'Asia/Shanghai');
  });

  test('calendar window expands recurring events into stable occurrences', () {
    final snapshot = WidgetSnapshotBuilder.build(
      [
        _event(
          'daily',
          2026,
          8,
          17,
          8,
          recurrence: const RecurrenceRule(rrule: 'FREQ=DAILY'),
        ),
      ],
      timezone: 'Asia/Shanghai',
      now: tz.TZDateTime(tz.local, 2026, 8, 19, 12),
    );

    final occurrences = (snapshot['calendar_events']! as List<dynamic>)
        .map((value) => value as Map<String, dynamic>)
        .toList(growable: false);
    expect(occurrences, hasLength(14));
    expect(occurrences, everyElement(containsPair('source_id', 'daily')));
    expect(
      occurrences.map((value) => value['id']),
      everyElement(startsWith('daily@')),
    );
  });

  test(
    'snapshot exposes only incomplete due items inside the active window',
    () {
      final snapshot = WidgetSnapshotBuilder.build(
        [
          _task('overdue', 2026, 8, 18, 9),
          _task('soon', 2026, 8, 19, 14),
          _task('done', 2026, 8, 20, 9, status: ItemStatus.done),
          _task('cancelled', 2026, 8, 20, 10, status: ItemStatus.cancelled),
          _task('outside', 2026, 8, 28, 9),
        ],
        timezone: 'Asia/Shanghai',
        now: tz.TZDateTime(tz.local, 2026, 8, 19, 12),
      );

      final due = snapshot['due_items']! as List<dynamic>;
      expect(due.map((value) => (value as Map<String, dynamic>)['id']), [
        'overdue',
        'soon',
      ]);
    },
  );
}

CalendarItem _event(
  String id,
  int year,
  int month,
  int day,
  int hour, {
  ItemStatus status = ItemStatus.todo,
  RecurrenceRule? recurrence,
}) {
  final start = tz.TZDateTime(tz.local, year, month, day, hour);
  return _item(
    id: id,
    type: ItemType.event,
    startAt: start,
    endAt: start.add(const Duration(hours: 1)),
    status: status,
    recurrence: recurrence,
  );
}

CalendarItem _task(
  String id,
  int year,
  int month,
  int day,
  int hour, {
  ItemStatus status = ItemStatus.todo,
}) => _item(
  id: id,
  type: ItemType.task,
  dueAt: tz.TZDateTime(tz.local, year, month, day, hour),
  status: status,
);

CalendarItem _item({
  required String id,
  required ItemType type,
  DateTime? startAt,
  DateTime? endAt,
  DateTime? dueAt,
  required ItemStatus status,
  RecurrenceRule? recurrence,
}) => CalendarItem(
  id: id,
  collectionId: 'collection_local',
  type: type,
  title: id,
  startAt: startAt,
  endAt: endAt,
  dueAt: dueAt,
  recurrence: recurrence,
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
