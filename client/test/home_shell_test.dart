import 'package:easy_calendar/features/shell/home_shell.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'calendar destination tracker detects a repeat tap on the active tab',
    () {
      final tracker = CalendarDestinationTapTracker();
      final firstTap = DateTime(2026, 8, 24, 9);

      expect(tracker.register(0, selectedIndex: 0, now: firstTap), isFalse);
      expect(
        tracker.register(
          0,
          selectedIndex: 0,
          now: firstTap.add(const Duration(milliseconds: 120)),
        ),
        isTrue,
      );
    },
  );

  test('calendar destination tracker supports switching from another tab', () {
    final tracker = CalendarDestinationTapTracker();
    final firstTap = DateTime(2026, 8, 24, 9);

    expect(tracker.register(0, selectedIndex: 2, now: firstTap), isFalse);
    expect(
      tracker.register(
        0,
        selectedIndex: 0,
        now: firstTap.add(const Duration(milliseconds: 120)),
      ),
      isTrue,
    );
  });

  test(
    'calendar destination tracker resets on other destinations or slow taps',
    () {
      final tracker = CalendarDestinationTapTracker();
      final firstTap = DateTime(2026, 8, 24, 9);

      expect(tracker.register(0, selectedIndex: 0, now: firstTap), isFalse);
      expect(
        tracker.register(
          1,
          selectedIndex: 0,
          now: firstTap.add(const Duration(milliseconds: 120)),
        ),
        isFalse,
      );
      expect(
        tracker.register(
          0,
          selectedIndex: 0,
          now: firstTap.add(const Duration(milliseconds: 240)),
        ),
        isFalse,
      );
      expect(
        tracker.register(
          0,
          selectedIndex: 0,
          now: firstTap.add(const Duration(milliseconds: 800)),
        ),
        isFalse,
      );
    },
  );
}
