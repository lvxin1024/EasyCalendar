import 'package:easy_calendar/domain/item.dart';
import 'package:easy_calendar/features/due/due_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

void main() {
  final now = DateTime.utc(2026, 8, 31, 12);

  setUpAll(() {
    tz_data.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));
  });

  test('open filter includes unfinished due items', () {
    expect(
      dueMatchesFilter(_task(DateTime.utc(2026, 9, 1)), DueFilter.open, now),
      isTrue,
    );
  });

  test('overdue filter includes unfinished past due items', () {
    expect(
      dueMatchesFilter(
        _task(DateTime.utc(2026, 8, 30)),
        DueFilter.overdue,
        now,
      ),
      isTrue,
    );
  });

  test('completed filter includes completed due items', () {
    expect(
      dueMatchesFilter(
        _task(DateTime.utc(2026, 8, 30), status: ItemStatus.done),
        DueFilter.completed,
        now,
      ),
      isTrue,
    );
  });

  testWidgets('embedded section exposes and switches all filters', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DueItemsSection(
            items: const [],
            tagColors: const {},
            onEdit: (_) {},
            onDelete: (_) {},
            onToggleCompleted: (_, _) {},
          ),
        ),
      ),
    );

    expect(find.text('待完成'), findsOneWidget);
    expect(find.text('已逾期'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);

    await tester.tap(find.text('已完成'));
    await tester.pump();

    final filter = tester.widget<SegmentedButton<DueFilter>>(
      find.byType(SegmentedButton<DueFilter>),
    );
    expect(filter.selected, {DueFilter.completed});
  });
}

CalendarItem _task(DateTime dueAt, {ItemStatus status = ItemStatus.todo}) =>
    CalendarItem(
      id: dueAt.toIso8601String(),
      collectionId: 'collection_local',
      type: ItemType.task,
      title: 'Due',
      dueAt: dueAt,
      timezone: 'UTC',
      allDay: false,
      status: status,
      reminderEnabled: false,
      reminderMinutes: 30,
      tags: const [],
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      version: 1,
    );
