import 'package:easy_calendar/features/calendar/calendar_navigation_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('month grid covers complete weeks around the month', () {
    final navigation = CalendarNavigationController(
      selectedDate: DateTime(2026, 8, 12),
    );

    expect(navigation.monthGridStart, DateTime(2026, 7, 27));
    expect(navigation.monthGridEnd, DateTime(2026, 9, 7));
    expect(
      navigation.monthGridEnd.difference(navigation.monthGridStart).inDays,
      42,
    );
  });

  test('week number jump selects the week start and week mode', () {
    final navigation = CalendarNavigationController(
      selectedDate: DateTime(2026, 8, 12),
    );

    navigation.selectDate(navigation.monthGridStart);
    navigation.setMode(CalendarViewMode.week);

    expect(navigation.selectedDate, DateTime(2026, 7, 27));
    expect(navigation.rangeStart, DateTime(2026, 7, 27));
  });
}
