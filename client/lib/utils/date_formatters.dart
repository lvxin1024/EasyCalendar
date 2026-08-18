import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../domain/item.dart';
import 'configured_time.dart';

String formatToday(BuildContext context, DateTime value) =>
    DateFormat.MMMMEEEEd(
      _localeName(context),
    ).format(inConfiguredTimezone(value));

String formatDate(BuildContext context, DateTime value) =>
    DateFormat.yMMMMd(_localeName(context)).format(inConfiguredTimezone(value));

String formatMonth(BuildContext context, DateTime value) =>
    DateFormat.yMMMM(_localeName(context)).format(value);

String formatMonthDay(BuildContext context, DateTime value) =>
    DateFormat.MMMd(_localeName(context)).format(value);

String formatNumericDate(BuildContext context, DateTime value) =>
    DateFormat.yMd(_localeName(context)).format(value);

String formatWeekday(BuildContext context, DateTime value) =>
    DateFormat.E(_localeName(context)).format(value);

String formatDateWithWeekday(BuildContext context, DateTime value) =>
    DateFormat.yMMMMEEEEd(_localeName(context)).format(value);

String formatCompactDateWithWeekday(BuildContext context, DateTime value) =>
    DateFormat.MEd(_localeName(context)).format(value);

class DateFormattingScope extends InheritedWidget {
  const DateFormattingScope({
    super.key,
    required this.clockFormat,
    required super.child,
  });

  final ClockFormat clockFormat;

  static ClockFormat clockFormatOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<DateFormattingScope>()
          ?.clockFormat ??
      ClockFormat.system;

  @override
  bool updateShouldNotify(DateFormattingScope oldWidget) =>
      oldWidget.clockFormat != clockFormat;
}

bool uses24HourClock(BuildContext context) {
  return switch (DateFormattingScope.clockFormatOf(context)) {
    ClockFormat.hour12 => false,
    ClockFormat.hour24 => true,
    ClockFormat.system =>
      MediaQuery.maybeOf(context)?.alwaysUse24HourFormat ??
          _localeDefaultsTo24Hours(context),
  };
}

String formatTime(BuildContext context, DateTime value) {
  final local = inConfiguredTimezone(value);
  final locale = _localeName(context);
  return DateFormat(
    uses24HourClock(context) ? 'HH:mm' : 'h:mm a',
    locale,
  ).format(local);
}

String formatHourLabel(BuildContext context, int hour) {
  final locale = _localeName(context);
  return DateFormat(
    uses24HourClock(context) ? 'HH:mm' : 'h a',
    locale,
  ).format(DateTime(2000, 1, 1, hour));
}

bool _localeDefaultsTo24Hours(BuildContext context) {
  final locale = _localeName(context);
  final pattern = DateFormat.jm(locale).pattern ?? '';
  return pattern.contains('H') || pattern.contains('k');
}

String _localeName(BuildContext context) =>
    Localizations.maybeLocaleOf(context)?.toString() ?? 'en';

String formatSchedule(BuildContext context, CalendarItem item) {
  final raw = item.scheduleAt;
  final value = raw == null ? null : inConfiguredTimezone(raw);
  if (value == null) return '未设置时间';
  if (item.allDay) return '${formatDate(context, value)} · 全天';
  final prefix = item.type == ItemType.task ? '截止' : formatDate(context, value);
  if (item.type == ItemType.event && item.endAt != null) {
    return '$prefix ${formatTime(context, value)}–${formatTime(context, item.endAt!)}';
  }
  return '$prefix ${formatTime(context, value)}';
}

String relativeDueLabel(DateTime dueAt, DateTime now) {
  final due = DateTime(dueAt.year, dueAt.month, dueAt.day);
  final today = DateTime(now.year, now.month, now.day);
  final days = due.difference(today).inDays;
  if (days < 0) return '逾期 ${-days} 天';
  if (days == 0) return '今天截止';
  if (days == 1) return '明天截止';
  return '$days 天后截止';
}
