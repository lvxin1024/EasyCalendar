import 'package:easy_calendar/ai/local_rule_parser.dart';
import 'package:easy_calendar/domain/item.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

void main() {
  setUpAll(() {
    tz_data.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));
  });

  test('extracts Chinese relative dates, tasks and recurrence offline', () {
    final result = const LocalRuleParser().extract(
      '明天下午三点评审，周五前提交报告，每周同步',
      now: DateTime.utc(2026, 8, 18, 2),
      timezone: 'Asia/Shanghai',
    );

    expect(result.candidates, hasLength(3));
    expect(result.candidates.first.type, ItemType.event);
    expect(result.candidates.first.startAt?.hour, 15);
    expect(result.candidates.first.startAt?.day, 19);
    expect(result.candidates[1].type, ItemType.task);
    expect(result.candidates[1].dueAt?.weekday, DateTime.friday);
    expect(result.candidates.last.recurrence?.rrule, 'FREQ=WEEKLY');
    expect(result.candidates.last.toDraft().recurrence?.frequency, 'WEEKLY');
    expect(result.warnings, isNotEmpty);
  });

  test('uses a deterministic source span and safe defaults', () {
    final result = const LocalRuleParser().extract(
      '整理资料',
      now: DateTime.utc(2026, 8, 18, 2),
      timezone: 'Asia/Shanghai',
    );

    final candidate = result.candidates.single;
    expect(candidate.type, ItemType.event);
    expect(candidate.startAt?.hour, 9);
    expect(candidate.sourceTextSpan?.start, 0);
    expect(candidate.sourceTextSpan?.end, 4);
  });
}
