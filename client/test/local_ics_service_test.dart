import 'dart:convert';

import 'package:easy_calendar/data/local_ics_service.dart';
import 'package:easy_calendar/domain/item.dart';
import 'package:easy_calendar/domain/recurrence.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

void main() {
  const service = LocalIcsService();

  setUpAll(() {
    tz_data.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));
  });

  test('parses timed, all-day, escaped text and recurrence fields', () {
    const content =
        'BEGIN:VCALENDAR\r\n'
        'VERSION:2.0\r\n'
        'PRODID:-//Test//EN\r\n'
        'BEGIN:VEVENT\r\n'
        'UID:timed@example.com\r\n'
        'DTSTART:20260818T010203Z\r\n'
        'DTEND:20260818T020304Z\r\n'
        'SUMMARY:Planning\\, review\r\n'
        'DESCRIPTION:Line one\\nLine two\\; details\r\n'
        'LOCATION:Room 1\r\n'
        'CATEGORIES:work,review\r\n'
        'RRULE:FREQ=WEEKLY;COUNT=3\r\n'
        'EXDATE:20260825T010203Z\r\n'
        'END:VEVENT\r\n'
        'BEGIN:VEVENT\r\n'
        'UID:all-day@example.com\r\n'
        'DTSTART;VALUE=DATE:20260820\r\n'
        'SUMMARY:Holiday\r\n'
        'END:VEVENT\r\n'
        'END:VCALENDAR\r\n';

    final plan = service.planImport(content, defaultTimezone: 'Asia/Shanghai');

    expect(plan.result.accepted, isTrue);
    expect(plan.result.created, {'events': 2});
    expect(plan.drafts, hasLength(2));
    final timed = plan.drafts.first;
    expect(timed.title, 'Planning, review');
    expect(timed.body, 'Line one\nLine two; details');
    expect(timed.startAt, DateTime.utc(2026, 8, 18, 1, 2, 3));
    expect(timed.endAt, DateTime.utc(2026, 8, 18, 2, 3, 4));
    expect(timed.timezone, 'UTC');
    expect(timed.tags, ['work', 'review']);
    expect(timed.recurrence?.rrule, 'FREQ=WEEKLY;COUNT=3');
    expect(timed.recurrence?.exdates, ['20260825T010203Z']);
    final allDay = plan.drafts.last;
    expect(allDay.allDay, isTrue);
    expect(allDay.startAt?.year, 2026);
    expect(allDay.startAt?.month, 8);
    expect(allDay.startAt?.day, 20);
    expect(allDay.endAt?.day, 21);
  });

  test('reports invalid events and duplicate items during preview', () {
    const content =
        'BEGIN:VCALENDAR\r\n'
        'VERSION:2.0\r\n'
        'PRODID:-//Test//EN\r\n'
        'BEGIN:VEVENT\r\n'
        'UID:duplicate@example.com\r\n'
        'DTSTART:20260818T010203Z\r\n'
        'SUMMARY:Duplicate\r\n'
        'END:VEVENT\r\n'
        'BEGIN:VEVENT\r\n'
        'UID:invalid@example.com\r\n'
        'SUMMARY:Missing start\r\n'
        'END:VEVENT\r\n'
        'END:VCALENDAR\r\n';
    final existing = _item(
      title: 'Duplicate',
      startAt: DateTime.utc(2026, 8, 18, 1, 2, 3),
    );

    final plan = service.planImport(
      content,
      defaultTimezone: 'Asia/Shanghai',
      existingItems: [existing],
    );

    expect(plan.result.accepted, isFalse);
    expect(plan.result.skipped, {'events': 1});
    expect(plan.result.issues, hasLength(1));
    expect(plan.result.issues.single.resourceId, 'invalid@example.com');
    expect(plan.drafts, isEmpty);
  });

  test('exports valid folded ICS that can be imported again', () {
    final item = _item(
      title: '项目复盘, weekly',
      body: '第一行\n第二行; ${'很长的说明' * 12}',
      startAt: DateTime.utc(2026, 8, 18, 1),
      endAt: DateTime.utc(2026, 8, 18, 2),
      recurrence: const RecurrenceRule(
        rrule: 'FREQ=WEEKLY;COUNT=2',
        exdates: ['20260825T010000Z'],
      ),
    );

    final content = service.export([
      item,
    ], generatedAt: DateTime.utc(2026, 8, 18));
    final physicalLines = const LineSplitter().convert(content);
    expect(
      physicalLines.every((line) => utf8.encode(line).length <= 75),
      isTrue,
    );
    expect(content, contains('SUMMARY:项目复盘\\, weekly'));
    expect(content, contains('RRULE:FREQ=WEEKLY;COUNT=2'));

    final imported = service.planImport(
      content,
      defaultTimezone: 'Asia/Shanghai',
    );
    expect(imported.result.accepted, isTrue);
    expect(imported.drafts.single.title, item.title);
    expect(imported.drafts.single.body, item.body);
    expect(imported.drafts.single.startAt, item.startAt);
  });
}

CalendarItem _item({
  required String title,
  String? body,
  required DateTime startAt,
  DateTime? endAt,
  RecurrenceRule? recurrence,
}) => CalendarItem(
  id: 'item_1',
  collectionId: 'collection_local',
  type: ItemType.event,
  title: title,
  body: body,
  startAt: startAt,
  endAt: endAt,
  recurrence: recurrence,
  timezone: 'UTC',
  allDay: false,
  status: ItemStatus.todo,
  reminderEnabled: false,
  reminderMinutes: 30,
  tags: const [],
  createdAt: DateTime.utc(2026, 8, 1),
  updatedAt: DateTime.utc(2026, 8, 1),
  version: 1,
);
