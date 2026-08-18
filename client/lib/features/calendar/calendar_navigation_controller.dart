import 'package:flutter/foundation.dart';

import '../../domain/item.dart';
import '../../domain/recurrence.dart';
import '../../utils/configured_time.dart';

enum CalendarViewMode { day, week, month }

class CalendarNavigationController extends ChangeNotifier {
  CalendarNavigationController({
    DateTime? selectedDate,
    CalendarViewMode initialMode = CalendarViewMode.day,
    int initialFirstDayOfWeek = DateTime.monday,
    DateTime Function()? clock,
  }) : _selectedDate = _dateOnly(selectedDate ?? (clock ?? configuredNow)()),
       _mode = initialMode,
       _firstDayOfWeek = initialFirstDayOfWeek,
       _clock = clock ?? configuredNow;

  DateTime _selectedDate;
  CalendarViewMode _mode;
  int _firstDayOfWeek;
  final DateTime Function() _clock;

  DateTime get selectedDate => _selectedDate;
  CalendarViewMode get mode => _mode;
  int get firstDayOfWeek => _firstDayOfWeek;

  DateTime get rangeStart => switch (_mode) {
    CalendarViewMode.day => _selectedDate,
    CalendarViewMode.week => startOfWeek(_selectedDate, _firstDayOfWeek),
    CalendarViewMode.month => DateTime(_selectedDate.year, _selectedDate.month),
  };

  DateTime get rangeEnd => switch (_mode) {
    CalendarViewMode.day => rangeStart.add(const Duration(days: 1)),
    CalendarViewMode.week => rangeStart.add(const Duration(days: 7)),
    CalendarViewMode.month => DateTime(
      _selectedDate.year,
      _selectedDate.month + 1,
    ),
  };

  List<DateTime> get visibleDates => List<DateTime>.generate(
    rangeEnd.difference(rangeStart).inDays,
    (index) => rangeStart.add(Duration(days: index)),
    growable: false,
  );

  DateTime get monthGridStart => startOfWeek(
    DateTime(_selectedDate.year, _selectedDate.month),
    _firstDayOfWeek,
  );

  DateTime get monthGridEnd {
    final monthEnd = DateTime(_selectedDate.year, _selectedDate.month + 1);
    final days = monthEnd.difference(monthGridStart).inDays;
    final rowCount = (days + 6) ~/ 7;
    return monthGridStart.add(Duration(days: rowCount * 7));
  }

  void setMode(CalendarViewMode value) {
    if (_mode == value) return;
    _mode = value;
    notifyListeners();
  }

  void selectDate(DateTime value) {
    final normalized = _dateOnly(value);
    if (_selectedDate == normalized) return;
    _selectedDate = normalized;
    notifyListeners();
  }

  void updateFirstDayOfWeek(int value, {bool notify = true}) {
    if (value < DateTime.monday || value > DateTime.sunday) return;
    if (_firstDayOfWeek == value) return;
    _firstDayOfWeek = value;
    if (notify) notifyListeners();
  }

  void goToToday({bool useDayView = false}) {
    _selectedDate = _dateOnly(_clock());
    if (useDayView) _mode = CalendarViewMode.day;
    notifyListeners();
  }

  void previous() => _move(-1);

  void next() => _move(1);

  List<CalendarItem> eventsInRange(
    List<CalendarItem> items, {
    DateTime? start,
    DateTime? end,
  }) {
    final fromDate = start ?? rangeStart;
    final toDate = end ?? rangeEnd;
    final from = configuredDateTime(
      year: fromDate.year,
      month: fromDate.month,
      day: fromDate.day,
    );
    final to = configuredDateTime(
      year: toDate.year,
      month: toDate.month,
      day: toDate.day,
    );
    final expanded = expandCalendarItems(items, fromDate, toDate);
    final events = expanded
        .where((item) {
          if (item.type != ItemType.event ||
              item.status == ItemStatus.cancelled ||
              item.startAt == null) {
            return false;
          }
          final itemStart = inConfiguredTimezone(item.startAt!);
          final rawEnd = item.endAt;
          if (rawEnd == null || !rawEnd.isAfter(item.startAt!)) {
            return !itemStart.isBefore(from) && itemStart.isBefore(to);
          }
          final itemEnd = inConfiguredTimezone(rawEnd);
          return itemStart.isBefore(to) && itemEnd.isAfter(from);
        })
        .toList(growable: false);
    events.sort((left, right) {
      final time = left.startAt!.compareTo(right.startAt!);
      return time == 0 ? left.id.compareTo(right.id) : time;
    });
    return events;
  }

  List<CalendarItem> eventsForDate(List<CalendarItem> items, DateTime date) =>
      eventsInRange(
        items,
        start: _dateOnly(date),
        end: _dateOnly(date).add(const Duration(days: 1)),
      );

  List<CalendarItem> calendarItemsInRange(List<CalendarItem> items) {
    final events = eventsInRange(items);
    final from = configuredDateTime(
      year: rangeStart.year,
      month: rangeStart.month,
      day: rangeStart.day,
    );
    final to = configuredDateTime(
      year: rangeEnd.year,
      month: rangeEnd.month,
      day: rangeEnd.day,
    );
    final dues = items.where((item) {
      if (item.type != ItemType.task ||
          item.status != ItemStatus.todo ||
          item.dueAt == null) {
        return false;
      }
      final due = inConfiguredTimezone(item.dueAt!);
      return !due.isBefore(from) && due.isBefore(to);
    });
    return [...events, ...dues];
  }

  void _move(int direction) {
    _selectedDate = switch (_mode) {
      CalendarViewMode.day => _selectedDate.add(Duration(days: direction)),
      CalendarViewMode.week => _selectedDate.add(Duration(days: 7 * direction)),
      CalendarViewMode.month => _moveMonth(_selectedDate, direction),
    };
    notifyListeners();
  }

  static DateTime _moveMonth(DateTime value, int delta) {
    final targetFirst = DateTime(value.year, value.month + delta);
    final targetLast = DateTime(targetFirst.year, targetFirst.month + 1, 0).day;
    return DateTime(
      targetFirst.year,
      targetFirst.month,
      value.day.clamp(1, targetLast),
    );
  }

  static DateTime _dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);
}

DateTime startOfWeek(DateTime date, int firstDayOfWeek) {
  final distance = (date.weekday - firstDayOfWeek + 7) % 7;
  return DateTime(date.year, date.month, date.day - distance);
}

int materialWeekdayToDateTime(int materialIndex) =>
    materialIndex == 0 ? DateTime.sunday : materialIndex;

int isoWeekNumber(DateTime date) {
  final normalized = DateTime(date.year, date.month, date.day);
  final thursday = normalized.add(Duration(days: 4 - normalized.weekday));
  final firstThursday = DateTime(thursday.year, 1, 4);
  final firstWeekStart = firstThursday.subtract(
    Duration(days: firstThursday.weekday - DateTime.monday),
  );
  return 1 + thursday.difference(firstWeekStart).inDays ~/ 7;
}
