import 'package:easy_calendar/domain/china_holiday.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final schedules = {
    2025: (
      holidays: [
        (101, 101),
        (128, 204),
        (404, 406),
        (501, 505),
        (531, 602),
        (1001, 1008),
      ],
      workdays: {126, 208, 427, 928, 1011},
    ),
    2026: (
      holidays: [
        (101, 103),
        (215, 223),
        (404, 406),
        (501, 505),
        (619, 621),
        (925, 927),
        (1001, 1007),
      ],
      workdays: {104, 214, 228, 509, 920, 1010},
    ),
  };

  for (final entry in schedules.entries) {
    test('${entry.key} marks only official weekday rest and weekend work', () {
      for (
        var date = DateTime.utc(entry.key);
        date.year == entry.key;
        date = date.add(const Duration(days: 1))
      ) {
        final monthDay = date.month * 100 + date.day;
        final isHoliday = entry.value.holidays.any(
          (range) => monthDay >= range.$1 && monthDay <= range.$2,
        );
        final expected = entry.value.workdays.contains(monthDay)
            ? ChinaDayAdjustment.work
            : isHoliday && date.weekday <= DateTime.friday
            ? ChinaDayAdjustment.rest
            : null;

        expect(chinaDayAdjustment(date), expected, reason: '$date');
      }
    });
  }

  test('uses the supplied calendar date regardless of time or UTC flag', () {
    for (final date in [
      DateTime(2026, 10, 1, 0, 1),
      DateTime(2026, 10, 1, 23, 59),
      DateTime.utc(2026, 10, 1, 23, 59),
    ]) {
      expect(chinaDayAdjustment(date), ChinaDayAdjustment.rest);
    }
    expect(
      chinaDayAdjustment(DateTime.utc(2026, 1, 4, 23, 59)),
      ChinaDayAdjustment.work,
    );
  });

  test('does not guess arrangements for unsupported years', () {
    for (final year in [2024, 2027, 2030]) {
      expect(chinaDayAdjustment(DateTime(year, 1, 1)), isNull);
      expect(chinaDayAdjustment(DateTime(year, 10, 1)), isNull);
    }
  });
}
