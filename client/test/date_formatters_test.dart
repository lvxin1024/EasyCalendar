import 'package:easy_calendar/domain/item.dart';
import 'package:easy_calendar/utils/date_formatters.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

void main() {
  setUpAll(() {
    tz_data.initializeTimeZones();
    tz.setLocalLocation(tz.UTC);
  });

  testWidgets('clock format can follow or override the system preference', (
    tester,
  ) async {
    Future<void> pump(ClockFormat format, {required bool system24Hour}) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(alwaysUse24HourFormat: system24Hour),
            child: DateFormattingScope(
              clockFormat: format,
              child: child ?? const SizedBox.shrink(),
            ),
          ),
          home: Builder(
            builder: (context) =>
                Text(formatTime(context, DateTime.utc(2026, 8, 18, 15, 5))),
          ),
        ),
      );
    }

    await pump(ClockFormat.system, system24Hour: true);
    expect(find.text('15:05'), findsOneWidget);

    await pump(ClockFormat.hour12, system24Hour: true);
    expect(find.text('3:05 PM'), findsOneWidget);

    await pump(ClockFormat.hour24, system24Hour: false);
    expect(find.text('15:05'), findsOneWidget);
  });
}
