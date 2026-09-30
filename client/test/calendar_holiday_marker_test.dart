import 'package:easy_calendar/domain/cycle_prediction.dart';
import 'package:easy_calendar/domain/item.dart';
import 'package:easy_calendar/features/calendar/calendar_date_label.dart';
import 'package:easy_calendar/features/calendar/calendar_month_grid.dart';
import 'package:easy_calendar/features/calendar/calendar_navigation_controller.dart';
import 'package:easy_calendar/features/calendar/calendar_time_grid.dart';
import 'package:easy_calendar/features/calendar/cycle_day_marker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

const _cycle = CycleDayState(
  kind: CycleDayKind.recorded,
  isStart: true,
  isEnd: false,
  isCenter: false,
);

void main() {
  setUpAll(() {
    tz_data.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));
  });

  testWidgets(
    'markers share small red text at the upper right with semantics',
    (tester) async {
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: Scaffold(
              body: Column(
                children: [
                  CalendarDateLabel(
                    date: DateTime(2026, 10, 1),
                    child: const Text('1'),
                  ),
                  CalendarDateLabel(
                    date: DateTime(2026, 10, 10),
                    child: const Text('10'),
                  ),
                  CalendarDateLabel(
                    date: DateTime(2026, 10, 4),
                    child: const Text('4'),
                  ),
                ],
              ),
            ),
          ),
        );

        expect(find.text('休'), findsOneWidget);
        expect(find.text('工'), findsOneWidget);
        expect(find.bySemanticsLabel('休息日'), findsOneWidget);
        expect(find.bySemanticsLabel('调休工作日'), findsOneWidget);
        final restStyle = tester.widget<Text>(find.text('休')).style!;
        expect(tester.widget<Text>(find.text('工')).style, restStyle);
        expect(restStyle.fontSize, lessThanOrEqualTo(11));
        expect(restStyle.color!.r, greaterThan(restStyle.color!.g));
        expect(restStyle.color!.r, greaterThan(restStyle.color!.b));
        for (final pair in [('休', '1'), ('工', '10')]) {
          final marker = tester.getRect(find.text(pair.$1));
          final number = tester.getRect(find.text(pair.$2));
          expect(marker.left, greaterThanOrEqualTo(number.right));
          expect(marker.top, lessThan(number.top));
        }
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('month dates retain selection and cycle markers', (tester) async {
    _setSize(tester, const Size(1000, 900));
    final navigation = CalendarNavigationController(
      selectedDate: DateTime(2026, 10, 1),
    );
    addTearDown(navigation.dispose);
    DateTime? selected;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CalendarMonthGrid(
            navigation: navigation,
            items: const [],
            onEdit: (_) {},
            onDateSelected: (date) => selected = date,
            showCycleMarkers: true,
            cycleStates: {DateTime(2026, 10, 1): _cycle},
          ),
        ),
      ),
    );

    expect(find.text('休'), findsNWidgets(5));
    expect(find.text('工'), findsOneWidget);
    expect(find.byType(CycleDayMarker), findsOneWidget);
    expect(
      tester.getRect(_labelFor(DateTime(2026, 10, 4))).right,
      lessThanOrEqualTo(1000),
    );
    final restDate = _labelFor(DateTime(2026, 10, 1));
    final workDate = _labelFor(DateTime(2026, 10, 10));
    expect(
      find.descendant(of: restDate, matching: find.text('休')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: workDate, matching: find.text('工')),
      findsOneWidget,
    );
    await tester.tap(find.descendant(of: restDate, matching: find.text('休')));
    expect(selected, DateTime(2026, 10, 1));
    await tester.tap(find.descendant(of: workDate, matching: find.text('工')));
    expect(selected, DateTime(2026, 10, 10));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'narrow month dates fit with holidays, events and cycle markers',
    (tester) async {
      _setSize(tester, const Size(360, 760));
      final date = DateTime(2026, 10, 1);
      final navigation = CalendarNavigationController(selectedDate: date);
      addTearDown(navigation.dispose);
      DateTime? selected;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CalendarMonthGrid(
              navigation: navigation,
              items: [
                CalendarItem(
                  id: 'holiday-event',
                  collectionId: 'collection_local',
                  type: ItemType.event,
                  title: 'Holiday plans',
                  startAt: tz.TZDateTime(tz.local, 2026, 10, 1),
                  timezone: 'Asia/Shanghai',
                  allDay: true,
                  status: ItemStatus.todo,
                  reminderEnabled: false,
                  reminderMinutes: 30,
                  tags: const [],
                  createdAt: date,
                  updatedAt: date,
                  version: 1,
                ),
              ],
              onEdit: (_) {},
              onDateSelected: (value) => selected = value,
              showCycleMarkers: true,
              cycleStates: {date: _cycle},
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Holiday plans'), findsOneWidget);
      expect(find.byType(CycleDayMarker), findsOneWidget);
      final restMarker = find.descendant(
        of: _labelFor(date),
        matching: find.text('休'),
      );
      await tester.ensureVisible(restMarker);
      await tester.pumpAndSettle();
      await tester.tap(restMarker);
      expect(selected, date);
      expect(tester.takeException(), isNull);
    },
  );

  for (final dayCount in [1, 7]) {
    testWidgets('$dayCount-day grid keeps markers clickable at narrow widths', (
      tester,
    ) async {
      _setSize(tester, const Size(360, 760));
      final dates = List.generate(
        dayCount,
        (index) => DateTime(2026, 1, 1 + index),
      );
      DateTime? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CalendarTimeGrid(
              dates: dates,
              items: const [],
              dueItems: const [],
              selectedDate: dates.first,
              hourHeight: 72,
              onHourHeightChanged: (_) {},
              onDateSelected: (date) => selected = date,
              onEdit: (_) {},
              onCreateTimedEvent: (_) async {},
              showCycleMarkers: true,
              cycleStates: {dates.first: _cycle},
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('休'), findsNWidgets(dayCount == 1 ? 1 : 2));
      expect(find.text('工'), dayCount == 1 ? findsNothing : findsOneWidget);
      expect(find.byType(CycleDayMarker), findsOneWidget);
      final restMarker = find.descendant(
        of: _labelFor(dates.first),
        matching: find.text('休'),
      );
      await tester.tap(restMarker);
      expect(selected, dates.first);
      if (dayCount == 7) {
        final workMarker = find.text('工');
        await tester.tap(workMarker);
        expect(selected, DateTime(2026, 1, 4));
        expect(
          find.descendant(
            of: _labelFor(DateTime(2026, 1, 3)),
            matching: find.text('休'),
          ),
          findsNothing,
        );
      }
      expect(tester.takeException(), isNull);
    });
  }
}

Finder _labelFor(DateTime date) => find.byWidgetPredicate(
  (widget) => widget is CalendarDateLabel && widget.date == date,
);

void _setSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}
