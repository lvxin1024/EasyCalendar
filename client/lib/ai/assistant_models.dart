import '../domain/item.dart';

class AiTextSpan {
  const AiTextSpan({required this.start, required this.end});

  final int start;
  final int end;
}

class AiCandidateIssue {
  const AiCandidateIssue({required this.index, required this.message});

  final int index;
  final String message;
}

class AiExtractionResult {
  const AiExtractionResult({
    required this.candidates,
    this.issues = const [],
    this.warnings = const [],
  });

  final List<AiCandidate> candidates;
  final List<AiCandidateIssue> issues;
  final List<String> warnings;
}

class AiCandidate {
  const AiCandidate({
    required this.tempId,
    required this.type,
    required this.title,
    this.body,
    this.startAt,
    this.endAt,
    this.dueAt,
    this.timezone = 'Asia/Shanghai',
    this.allDay = false,
    this.location,
    this.priority,
    this.confidence = 1,
    this.reasoning,
    this.sourceTextSpan,
    this.reminders = const [],
  });

  factory AiCandidate.fromJson(Map<String, dynamic> json) {
    final tempId = _required(json['temp_id'], 'temp_id');
    final title = _required(json['title'], 'title');
    final typeName = _required(json['type'], 'type');
    final type = switch (typeName) {
      'event' => ItemType.event,
      'task' => ItemType.task,
      'note' => ItemType.note,
      _ => throw FormatException('Unsupported candidate type: $typeName'),
    };
    final confidence = (json['confidence'] as num?)?.toDouble() ?? 1;
    if (confidence < 0 || confidence > 1) {
      throw const FormatException(
        'Candidate confidence must be between 0 and 1',
      );
    }
    final rawSpan = json['source_text_span'];
    AiTextSpan? span;
    if (rawSpan != null) {
      if (rawSpan is! Map) {
        throw const FormatException('source_text_span must be an object');
      }
      span = AiTextSpan(
        start:
            (rawSpan['start'] as num?)?.toInt() ??
            (throw const FormatException('source span start is required')),
        end:
            (rawSpan['end'] as num?)?.toInt() ??
            (throw const FormatException('source span end is required')),
      );
      if (span.start < 0 || span.end < span.start) {
        throw const FormatException('Invalid source text span');
      }
    }
    final startAt = _date(json['start_at']);
    final endAt = _date(json['end_at']);
    final dueAt = _date(json['due_at']);
    if (type == ItemType.event && startAt == null) {
      throw const FormatException('Event candidate requires start_at');
    }
    if (type == ItemType.task && dueAt == null) {
      throw const FormatException('Task candidate requires due_at');
    }
    if (startAt != null && endAt != null && endAt.isBefore(startAt)) {
      throw const FormatException('Candidate end_at cannot be before start_at');
    }
    final priority = (json['priority'] as num?)?.toInt();
    if (priority != null && (priority < 0 || priority > 3)) {
      throw const FormatException('Candidate priority must be between 0 and 3');
    }
    return AiCandidate(
      tempId: tempId,
      type: type,
      title: title,
      body: json['body'] as String?,
      startAt: startAt,
      endAt: endAt,
      dueAt: dueAt,
      timezone: (json['timezone'] as String?)?.trim().isNotEmpty == true
          ? (json['timezone'] as String).trim()
          : 'Asia/Shanghai',
      allDay: json['all_day'] as bool? ?? false,
      location: json['location'] as String?,
      priority: priority,
      confidence: confidence,
      reasoning: json['reasoning'] as String?,
      sourceTextSpan: span,
      reminders: json['reminders'] is List
          ? (json['reminders'] as List)
                .whereType<Map>()
                .map((value) => Map<String, dynamic>.from(value))
                .toList(growable: false)
          : const [],
    );
  }

  final String tempId;
  final ItemType type;
  final String title;
  final String? body;
  final DateTime? startAt;
  final DateTime? endAt;
  final DateTime? dueAt;
  final String timezone;
  final bool allDay;
  final String? location;
  final int? priority;
  final double confidence;
  final String? reasoning;
  final AiTextSpan? sourceTextSpan;
  final List<Map<String, dynamic>> reminders;

  AiCandidate copyWith({
    ItemType? type,
    String? title,
    String? body,
    DateTime? startAt,
    DateTime? endAt,
    DateTime? dueAt,
    String? location,
    int? priority,
  }) => AiCandidate(
    tempId: tempId,
    type: type ?? this.type,
    title: title ?? this.title,
    body: body ?? this.body,
    startAt: startAt ?? this.startAt,
    endAt: endAt ?? this.endAt,
    dueAt: dueAt ?? this.dueAt,
    timezone: timezone,
    allDay: allDay,
    location: location,
    priority: priority,
    confidence: confidence,
    reasoning: reasoning,
    sourceTextSpan: sourceTextSpan,
    reminders: reminders,
  );

  ItemDraft toDraft() => ItemDraft(
    type: type,
    title: title,
    body: body,
    startAt: startAt,
    endAt: endAt,
    dueAt: dueAt,
    timezone: timezone,
    allDay: allDay,
    location: location,
    priority: priority,
    reminderEnabled: reminders.any(
      (value) => value['enabled'] as bool? ?? true,
    ),
    reminderMinutes: _suggestedReminderMinutes,
  );

  int get _suggestedReminderMinutes {
    for (final reminder in reminders) {
      final value = reminder['minutes_before'];
      if (value is num && value >= 0) return value.toInt();
    }
    return 30;
  }

  Map<String, dynamic> toJson() => {
    'temp_id': tempId,
    'type': switch (type) {
      ItemType.event => 'event',
      ItemType.task => 'task',
      ItemType.note => 'note',
    },
    'title': title,
    if (body != null) 'body': body,
    if (startAt != null) 'start_at': startAt!.toIso8601String(),
    if (endAt != null) 'end_at': endAt!.toIso8601String(),
    if (dueAt != null) 'due_at': dueAt!.toIso8601String(),
    'timezone': timezone,
    'all_day': allDay,
    if (location != null) 'location': location,
    if (priority != null) 'priority': priority,
    'confidence': confidence,
    if (reasoning != null) 'reasoning': reasoning,
    if (sourceTextSpan != null)
      'source_text_span': {
        'start': sourceTextSpan!.start,
        'end': sourceTextSpan!.end,
      },
    'reminders': reminders,
  };

  static String _required(Object? value, String field) {
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('$field is required');
    }
    return value.trim();
  }

  static DateTime? _date(Object? value) {
    if (value == null) return null;
    if (value is! String) {
      throw const FormatException('Candidate time must be an ISO string');
    }
    return DateTime.tryParse(value) ??
        (throw FormatException('Invalid candidate time: $value'));
  }
}

class CandidateWorkbench {
  CandidateWorkbench(Iterable<AiCandidate> initial) : candidates = [...initial];

  final List<AiCandidate> candidates;

  void edit(int index, AiCandidate value) => candidates[index] = value;

  AiCandidate reject(int index) => candidates.removeAt(index);

  void split(int index, Iterable<AiCandidate> replacements) {
    candidates
      ..removeAt(index)
      ..insertAll(index, replacements);
  }

  AiCandidate merge(int firstIndex, int secondIndex) {
    final first = candidates[firstIndex];
    final second = candidates[secondIndex];
    final merged = first.copyWith(
      title: '${first.title} / ${second.title}',
      body: [
        first.body,
        second.body,
      ].whereType<String>().where((value) => value.isNotEmpty).join('\n'),
      endAt: second.endAt ?? first.endAt,
    );
    final low = firstIndex < secondIndex ? firstIndex : secondIndex;
    final high = firstIndex < secondIndex ? secondIndex : firstIndex;
    candidates
      ..removeAt(high)
      ..removeAt(low)
      ..insert(low, merged);
    return merged;
  }
}
