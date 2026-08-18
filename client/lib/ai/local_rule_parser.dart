import 'package:timezone/timezone.dart' as tz;

import '../domain/item.dart';
import '../domain/recurrence.dart';
import '../utils/configured_time.dart';
import 'assistant_models.dart';

class LocalRuleParser {
  const LocalRuleParser();

  AiExtractionResult extract(
    String text, {
    required DateTime now,
    required String timezone,
  }) {
    final segments = text
        .split(RegExp(r'\s*(?:[,，;；]|然后|接着|之后)\s*'))
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    final candidates = <AiCandidate>[];
    var searchFrom = 0;
    for (var index = 0; index < segments.length; index++) {
      final segment = segments[index];
      final startOffset = text.indexOf(segment, searchFrom);
      searchFrom = startOffset < 0 ? searchFrom : startOffset + segment.length;
      final date = _date(segment, now);
      final time = _time(segment);
      final start = configuredDateTime(
        year: date.year,
        month: date.month,
        day: date.day,
        hour: time.$1,
        minute: time.$2,
      );
      final isTask = RegExp(
        r'截止|提交|完成|待办|提醒|任务|todo',
        caseSensitive: false,
      ).hasMatch(segment);
      final recurrence = _recurrence(segment);
      candidates.add(
        AiCandidate(
          tempId: 'local_${index + 1}',
          type: isTask ? ItemType.task : ItemType.event,
          title: segment,
          startAt: isTask ? null : start,
          endAt: isTask ? null : start.add(const Duration(hours: 1)),
          dueAt: isTask ? start : null,
          timezone: timezone,
          confidence: 0.78,
          reasoning: 'local_rule_parser',
          sourceTextSpan: AiTextSpan(
            start: startOffset < 0 ? 0 : startOffset,
            end: startOffset < 0
                ? segment.length
                : startOffset + segment.length,
          ),
          recurrence: recurrence,
        ),
      );
    }
    return AiExtractionResult(
      candidates: candidates,
      warnings: const ['使用本地规则解析器，复杂表达式可能需要手动校对。'],
    );
  }

  static DateTime _date(String text, DateTime now) {
    final localNow = tz.TZDateTime.from(now, tz.local);
    if (text.contains('后天')) return localNow.add(const Duration(days: 2));
    if (text.contains('明天')) return localNow.add(const Duration(days: 1));
    if (text.contains('昨天')) return localNow.subtract(const Duration(days: 1));
    final numeric = RegExp(r'(\d{1,2})月(\d{1,2})日?').firstMatch(text);
    if (numeric != null) {
      var year = localNow.year;
      final month = int.parse(numeric.group(1)!);
      final day = int.parse(numeric.group(2)!);
      if (month < localNow.month - 6) year += 1;
      return configuredDateTime(year: year, month: month, day: day);
    }
    const weekdays = {
      '一': DateTime.monday,
      '二': DateTime.tuesday,
      '三': DateTime.wednesday,
      '四': DateTime.thursday,
      '五': DateTime.friday,
      '六': DateTime.saturday,
      '日': DateTime.sunday,
      '天': DateTime.sunday,
    };
    final weekday = RegExp(r'(?:周|星期)([一二三四五六日天])').firstMatch(text);
    final target = weekday == null ? null : weekdays[weekday.group(1)];
    if (target != null) {
      var days = (target - localNow.weekday) % 7;
      if (days == 0) days = 7;
      return localNow.add(Duration(days: days));
    }
    return localNow;
  }

  static (int, int) _time(String text) {
    final match = RegExp(
      r'(上午|下午|晚上|凌晨)?\s*(\d{1,2})(?:[:：](\d{1,2}))?\s*(?:点|时)?',
    ).firstMatch(text);
    final chinese = match == null
        ? RegExp(r'(上午|下午|晚上|凌晨)?\s*([零〇一二两三四五六七八九十]{1,3})点').firstMatch(text)
        : null;
    if (match == null && chinese == null) return (9, 0);
    final period = match?.group(1) ?? chinese?.group(1);
    var hour = match == null
        ? _chineseNumber(chinese!.group(2)!)
        : int.parse(match.group(2)!);
    final minute = int.tryParse(match?.group(3) ?? '0') ?? 0;
    if ((period == '下午' || period == '晚上') && hour < 12) hour += 12;
    if (period == '凌晨' && hour == 12) hour = 0;
    return (hour.clamp(0, 23), minute.clamp(0, 59));
  }

  static int _chineseNumber(String value) {
    const digits = {
      '零': 0,
      '〇': 0,
      '一': 1,
      '二': 2,
      '两': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
    };
    if (value == '十') return 10;
    if (value.startsWith('十')) return 10 + (digits[value.substring(1)] ?? 0);
    if (value.endsWith('十')) return (digits[value.substring(0, 1)] ?? 1) * 10;
    if (value.contains('十')) {
      final parts = value.split('十');
      return (digits[parts.first] ?? 1) * 10 + (digits[parts.last] ?? 0);
    }
    return digits[value] ?? 9;
  }

  static RecurrenceRule? _recurrence(String text) {
    if (text.contains('每天') || text.contains('每日')) {
      return const RecurrenceRule(rrule: 'FREQ=DAILY');
    }
    if (text.contains('每周') || text.contains('每星期')) {
      return const RecurrenceRule(rrule: 'FREQ=WEEKLY');
    }
    if (text.contains('每月')) {
      return const RecurrenceRule(rrule: 'FREQ=MONTHLY');
    }
    if (text.contains('每年')) {
      return const RecurrenceRule(rrule: 'FREQ=YEARLY');
    }
    return null;
  }
}
