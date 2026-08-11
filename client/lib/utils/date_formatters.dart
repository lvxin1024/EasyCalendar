import 'package:intl/intl.dart';

import '../domain/item.dart';
import 'configured_time.dart';

String formatToday(DateTime value) =>
    DateFormat('M月d日 EEEE', 'zh_CN').format(inConfiguredTimezone(value));

String formatDate(DateTime value) =>
    DateFormat('yyyy年M月d日', 'zh_CN').format(inConfiguredTimezone(value));

String formatTime(DateTime value) =>
    DateFormat('HH:mm', 'zh_CN').format(inConfiguredTimezone(value));

String formatSchedule(CalendarItem item) {
  final raw = item.scheduleAt;
  final value = raw == null ? null : inConfiguredTimezone(raw);
  if (value == null) return '未设置时间';
  if (item.allDay) return '${formatDate(value)} · 全天';
  final prefix = item.type == ItemType.task ? '截止' : formatDate(value);
  if (item.type == ItemType.event && item.endAt != null) {
    return '$prefix ${formatTime(value)}–${formatTime(item.endAt!)}';
  }
  return '$prefix ${formatTime(value)}';
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
