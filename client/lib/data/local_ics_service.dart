import 'dart:convert';

import 'package:icalendar_parser/icalendar_parser.dart';
import 'package:timezone/timezone.dart' as tz;

import '../domain/item.dart';
import '../domain/recurrence.dart';
import 'transfer_models.dart';

class LocalIcsImportPlan {
  const LocalIcsImportPlan({required this.result, required this.events});

  final TransferResult result;
  final List<LocalIcsEvent> events;

  List<ItemDraft> get drafts =>
      events.map((event) => event.draft).toList(growable: false);
}

class LocalIcsEvent {
  const LocalIcsEvent({required this.externalId, required this.draft});

  final String externalId;
  final ItemDraft draft;
}

class LocalIcsService {
  const LocalIcsService();

  LocalIcsImportPlan planImport(
    String content, {
    required String defaultTimezone,
    Iterable<CalendarItem> existingItems = const [],
    bool deduplicate = true,
  }) {
    final calendar = ICalendar.fromString(content);
    final events = <LocalIcsEvent>[];
    final issues = <TransferIssue>[];
    final known = existingItems.map(_itemFingerprint).toSet();
    var skipped = 0;
    var eventIndex = 0;

    for (final component in calendar.data) {
      if (component['type'] != 'VEVENT') continue;
      final index = eventIndex++;
      try {
        final draft = _eventDraft(component, defaultTimezone);
        final fingerprint = _draftFingerprint(draft);
        if (deduplicate && !known.add(fingerprint)) {
          skipped += 1;
          continue;
        }
        final uid = _text(component['uid'])?.trim();
        events.add(
          LocalIcsEvent(
            externalId: uid?.isNotEmpty == true ? uid! : fingerprint,
            draft: draft,
          ),
        );
      } catch (error) {
        issues.add(
          TransferIssue(
            resourceType: 'events',
            index: index,
            resourceId: _text(component['uid']),
            message: error is FormatException
                ? error.message.toString()
                : '无法解析日程：$error',
          ),
        );
      }
    }

    if (eventIndex == 0) {
      issues.add(
        const TransferIssue(
          resourceType: 'events',
          index: 0,
          message: 'ICS 文件中没有 VEVENT 日程',
        ),
      );
    }

    return LocalIcsImportPlan(
      result: TransferResult(
        accepted: issues.isEmpty,
        committed: false,
        format: 'ics',
        created: {if (events.isNotEmpty) 'events': events.length},
        skipped: {if (skipped > 0) 'events': skipped},
        conflicts: const {},
        issues: issues,
      ),
      events: List.unmodifiable(events),
    );
  }

  String export(Iterable<CalendarItem> items, {DateTime? generatedAt}) {
    final now = (generatedAt ?? DateTime.now()).toUtc();
    final lines = <String>[
      'BEGIN:VCALENDAR',
      'VERSION:2.0',
      'PRODID:-//EasyCalendar//Local Client//ZH',
      'CALSCALE:GREGORIAN',
    ];
    for (final item in items) {
      if (item.type != ItemType.event ||
          item.startAt == null ||
          item.isDeleted) {
        continue;
      }
      lines.addAll(_eventLines(item, now));
    }
    lines.add('END:VCALENDAR');
    return '${lines.expand(_foldLine).join('\r\n')}\r\n';
  }

  static ItemDraft _eventDraft(
    Map<String, dynamic> event,
    String defaultTimezone,
  ) {
    final title = _unescapeText(_text(event['summary']) ?? '').trim();
    if (title.isEmpty) throw const FormatException('日程缺少 SUMMARY 标题');
    final rawStart = event['dtstart'];
    if (rawStart is! IcsDateTime) {
      throw const FormatException('日程缺少有效 DTSTART');
    }
    final allDay = RegExp(r'^\d{8}$').hasMatch(rawStart.dt.trim());
    final start = _parseDate(rawStart, defaultTimezone);
    final rawEnd = event['dtend'];
    final end = rawEnd is IcsDateTime
        ? _parseDate(rawEnd, defaultTimezone)
        : (allDay ? start.add(const Duration(days: 1)) : null);
    if (end != null && end.isBefore(start)) {
      throw const FormatException('DTEND 不能早于 DTSTART');
    }
    final rawRule = _text(event['rrule'])?.trim();
    final exdates = (event['exdate'] as List<dynamic>? ?? const [])
        .whereType<IcsDateTime>()
        .map((value) => value.dt.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);

    return ItemDraft(
      type: ItemType.event,
      title: title,
      body: _optionalText(event['description']),
      startAt: start,
      endAt: end,
      recurrence: rawRule == null || rawRule.isEmpty
          ? null
          : RecurrenceRule(rrule: rawRule, exdates: exdates),
      timezone: rawStart.tzid?.trim().isNotEmpty == true
          ? rawStart.tzid!.trim()
          : (rawStart.dt.trim().endsWith('Z') ? 'UTC' : defaultTimezone),
      allDay: allDay,
      location: _optionalText(event['location']),
      tags: (event['categories'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .map(_unescapeText)
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toList(growable: false),
    );
  }

  static DateTime _parseDate(IcsDateTime value, String defaultTimezone) {
    final raw = value.dt.trim();
    final match = RegExp(
      r'^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})?(Z)?)?$',
    ).firstMatch(raw);
    if (match == null) throw FormatException('不支持的日期格式：$raw');
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    final hour = int.parse(match.group(4) ?? '0');
    final minute = int.parse(match.group(5) ?? '0');
    final second = int.parse(match.group(6) ?? '0');
    if (match.group(7) != null) {
      return DateTime.utc(year, month, day, hour, minute, second);
    }
    final timezoneName = value.tzid?.trim().isNotEmpty == true
        ? value.tzid!.trim()
        : defaultTimezone;
    try {
      return tz.TZDateTime(
        tz.getLocation(timezoneName),
        year,
        month,
        day,
        hour,
        minute,
        second,
      );
    } catch (_) {
      throw FormatException('无法识别时区：$timezoneName');
    }
  }

  static List<String> _eventLines(CalendarItem item, DateTime generatedAt) {
    final lines = <String>[
      'BEGIN:VEVENT',
      'UID:${_escapeText('${item.id}@easycalendar.local')}',
      'DTSTAMP:${_utcDateTime(generatedAt)}',
    ];
    if (item.allDay) {
      lines.add('DTSTART;VALUE=DATE:${_date(item.startAt!, item.timezone)}');
      if (item.endAt != null) {
        lines.add('DTEND;VALUE=DATE:${_date(item.endAt!, item.timezone)}');
      }
    } else {
      lines.add('DTSTART:${_utcDateTime(item.startAt!)}');
      if (item.endAt != null) lines.add('DTEND:${_utcDateTime(item.endAt!)}');
    }
    lines.add('SUMMARY:${_escapeText(item.title)}');
    if (item.body?.isNotEmpty == true) {
      lines.add('DESCRIPTION:${_escapeText(item.body!)}');
    }
    if (item.location?.isNotEmpty == true) {
      lines.add('LOCATION:${_escapeText(item.location!)}');
    }
    if (item.tags.isNotEmpty) {
      lines.add('CATEGORIES:${item.tags.map(_escapeText).join(',')}');
    }
    final recurrence = item.recurrence;
    if (recurrence != null && recurrence.rrule.trim().isNotEmpty) {
      lines.add(
        'RRULE:${recurrence.rrule.trim().replaceFirst(RegExp(r'^RRULE:'), '')}',
      );
      if (recurrence.exdates.isNotEmpty) {
        lines.add('EXDATE:${recurrence.exdates.join(',')}');
      }
      if (recurrence.rdates.isNotEmpty) {
        lines.add('RDATE:${recurrence.rdates.join(',')}');
      }
    }
    lines.add('END:VEVENT');
    return lines;
  }

  static String _date(DateTime value, String timezoneName) {
    var local = value;
    try {
      local = tz.TZDateTime.from(value, tz.getLocation(timezoneName));
    } catch (_) {
      local = tz.TZDateTime.from(value, tz.local);
    }
    return '${_four(local.year)}${_two(local.month)}${_two(local.day)}';
  }

  static String _utcDateTime(DateTime value) {
    final utc = value.toUtc();
    return '${_four(utc.year)}${_two(utc.month)}${_two(utc.day)}T'
        '${_two(utc.hour)}${_two(utc.minute)}${_two(utc.second)}Z';
  }

  static Iterable<String> _foldLine(String line) sync* {
    var current = StringBuffer();
    var bytes = 0;
    const limit = 75;
    for (final rune in line.runes) {
      final character = String.fromCharCode(rune);
      final size = utf8.encode(character).length;
      if (bytes > 0 && bytes + size > limit) {
        yield current.toString();
        current = StringBuffer(' ');
        bytes = 1;
      }
      current.write(character);
      bytes += size;
    }
    yield current.toString();
  }

  static String _draftFingerprint(ItemDraft draft) => [
    draft.title.trim(),
    draft.body?.trim() ?? '',
    draft.startAt?.toUtc().toIso8601String() ?? '',
    draft.endAt?.toUtc().toIso8601String() ?? '',
    draft.allDay,
    draft.location?.trim() ?? '',
    draft.recurrence?.rrule ?? '',
    ...(draft.recurrence?.exdates ?? const []),
    ...([...draft.tags]..sort()),
  ].join('\u001f');

  static String _itemFingerprint(CalendarItem item) =>
      _draftFingerprint(item.toDraft());

  static String? _optionalText(Object? value) {
    final text = _unescapeText(_text(value) ?? '').trim();
    return text.isEmpty ? null : text;
  }

  static String? _text(Object? value) => value is String ? value : null;

  static String _unescapeText(String value) => value
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\N', '\n')
      .replaceAll(r'\,', ',')
      .replaceAll(r'\;', ';')
      .replaceAll(r'\\', '\\');

  static String _escapeText(String value) => value
      .replaceAll('\\', r'\\')
      .replaceAll('\r\n', r'\n')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\n')
      .replaceAll(',', r'\,')
      .replaceAll(';', r'\;');

  static String _two(int value) => value.toString().padLeft(2, '0');

  static String _four(int value) => value.toString().padLeft(4, '0');
}
