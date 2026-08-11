import 'package:intl/intl.dart';

import '../utils/configured_time.dart';
import 'item.dart';

class RecurrenceRule {
  const RecurrenceRule({
    required this.rrule,
    this.exdates = const [],
    this.rdates = const [],
  });

  factory RecurrenceRule.fromJson(Map<String, Object?> json) => RecurrenceRule(
    rrule: json['rrule'] as String,
    exdates: (json['exdates'] as List<Object?>? ?? const []).cast<String>(),
    rdates: (json['rdates'] as List<Object?>? ?? const []).cast<String>(),
  );

  final String rrule;
  final List<String> exdates;
  final List<String> rdates;

  Map<String, Object?> toJson() => {
    'rrule': rrule,
    'exdates': exdates,
    'rdates': rdates,
  };

  String get frequency => _parts['FREQ'] ?? '';

  Map<String, String> get _parts => {
    for (final part in rrule.split(';'))
      if (part.contains('=')) part.split('=').first: part.split('=').last,
  };
}

enum RecurrenceFrequency { none, daily, weekdays, weekly, monthly, yearly }

List<CalendarItem> expandCalendarItems(
  Iterable<CalendarItem> items,
  DateTime from,
  DateTime to,
) {
  final expanded = <CalendarItem>[];
  for (final item in items) {
    if (item.recurrence == null || item.startAt == null) {
      expanded.add(item);
      continue;
    }
    expanded.addAll(_expandItem(item, from, to));
  }
  return expanded;
}

List<CalendarItem> _expandItem(CalendarItem item, DateTime from, DateTime to) {
  final start = inConfiguredTimezone(item.startAt!);
  final lower = configuredDateTime(
    year: from.year,
    month: from.month,
    day: from.day,
  );
  final upper = configuredDateTime(year: to.year, month: to.month, day: to.day);
  final parts = item.recurrence!._parts;
  final frequency = parts['FREQ'];
  final interval = int.tryParse(parts['INTERVAL'] ?? '1') ?? 1;
  final count = int.tryParse(parts['COUNT'] ?? '');
  final until = _parseUntil(parts['UNTIL']);
  final weekdays = _parseWeekdays(parts['BYDAY']);
  final duration = item.endAt?.difference(item.startAt!);
  final results = <CalendarItem>[];
  var occurrenceIndex = 0;
  var cursor = DateTime(start.year, start.month, start.day);
  final scanEnd = upper.add(const Duration(days: 1));
  while (cursor.isBefore(scanEnd)) {
    final candidate = configuredDateTime(
      year: cursor.year,
      month: cursor.month,
      day: cursor.day,
      hour: start.hour,
      minute: start.minute,
    );
    final matches = _matches(
      frequency: frequency,
      interval: interval,
      start: start,
      candidate: candidate,
      weekdays: weekdays,
    );
    if (matches) {
      occurrenceIndex += 1;
      final withinCount = count == null || occurrenceIndex <= count;
      final withinUntil = until == null || !candidate.isAfter(until);
      if (withinCount && withinUntil) {
        final excluded = item.recurrence!.exdates.any(
          (value) => _sameInstant(_parseDate(value), candidate),
        );
        if (!excluded &&
            !candidate.isBefore(lower) &&
            candidate.isBefore(upper)) {
          results.add(
            item.copyWith(
              startAt: candidate,
              endAt: duration == null ? null : candidate.add(duration),
              recurrence: null,
            ),
          );
        }
      }
      if ((count != null && occurrenceIndex >= count) ||
          (until != null && candidate.isAfter(until))) {
        break;
      }
    }
    cursor = cursor.add(const Duration(days: 1));
  }
  return results;
}

bool _matches({
  required String? frequency,
  required int interval,
  required DateTime start,
  required DateTime candidate,
  required List<int> weekdays,
}) {
  final days = candidate
      .difference(DateTime(start.year, start.month, start.day))
      .inDays;
  if (days < 0) return false;
  switch (frequency) {
    case 'DAILY':
      return days % interval == 0;
    case 'WEEKLY':
      final week = days ~/ 7;
      final selected = weekdays.isEmpty ? [start.weekday] : weekdays;
      return week % interval == 0 && selected.contains(candidate.weekday);
    case 'MONTHLY':
      final months =
          (candidate.year - start.year) * 12 + candidate.month - start.month;
      return months >= 0 &&
          months % interval == 0 &&
          candidate.day == start.day;
    case 'YEARLY':
      final years = candidate.year - start.year;
      return years >= 0 &&
          years % interval == 0 &&
          candidate.month == start.month &&
          candidate.day == start.day;
    default:
      return false;
  }
}

List<int> _parseWeekdays(String? value) {
  const values = {
    'MO': 1,
    'TU': 2,
    'WE': 3,
    'TH': 4,
    'FR': 5,
    'SA': 6,
    'SU': 7,
  };
  return (value ?? '')
      .split(',')
      .map((part) => values[part.replaceAll(RegExp(r'[^A-Z]'), '')])
      .whereType<int>()
      .toList();
}

DateTime? _parseUntil(String? value) =>
    value == null ? null : _parseDate(value);

DateTime _parseDate(String value) {
  final normalized = value.trim();
  try {
    return DateTime.parse(normalized.replaceFirst('Z', '+00:00')).toLocal();
  } catch (_) {
    if (RegExp(r'^\d{8}$').hasMatch(normalized)) {
      return DateTime(
        int.parse(normalized.substring(0, 4)),
        int.parse(normalized.substring(4, 6)),
        int.parse(normalized.substring(6, 8)),
        23,
        59,
        59,
      );
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }
}

bool _sameInstant(DateTime left, DateTime right) =>
    left.toUtc().difference(right.toUtc()).inSeconds.abs() < 1;

String recurrenceUntil(DateTime value) => DateFormat('yyyyMMdd').format(value);
