import 'package:easy_calendar/domain/cycle_prediction.dart';
import 'package:easy_calendar/features/calendar/calendar_month_grid.dart';
import 'package:easy_calendar/features/calendar/calendar_navigation_controller.dart';
import 'package:easy_calendar/features/calendar/calendar_time_grid.dart';
import 'package:easy_calendar/features/calendar/cycle_day_marker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

void main() {
  setUpAll(() {
    tz_data.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));
  });

  testWidgets(
    'month view exposes recorded cycle markers without hiding dates',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final navigation = CalendarNavigationController(
        selectedDate: DateTime(2026, 8, 12),
      );
      addTearDown(navigation.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CalendarMonthGrid(
              navigation: navigation,
              items: const [],
              onEdit: (_) {},
              onDateSelected: (_) {},
              showCycleMarkers: true,
              cycleStates: {
                DateTime(2026, 8, 12): const CycleDayState(
                  kind: CycleDayKind.recorded,
                  isStart: true,
                  isEnd: false,
                  isCenter: false,
                ),
              },
            ),
          ),
        ),
      );

      expect(find.text('12'), findsOneWidget);
      expect(find.byType(CycleDayMarker), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('week view exposes predicted markers in the date header', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final dates = List.generate(
      7,
      (index) => DateTime(2026, 8, 10 + index),
      growable: false,
    );

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
            onDateSelected: (_) {},
            onEdit: (_) {},
            onCreateTimedEvent: (_) async {},
            showCycleMarkers: true,
            cycleStates: {
              DateTime(2026, 8, 12): const CycleDayState(
                kind: CycleDayKind.predicted,
                isStart: true,
                isEnd: false,
                isCenter: true,
              ),
            },
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(CycleDayMarker), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
