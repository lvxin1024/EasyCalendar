enum CycleFlowLevel { light, medium, heavy }

enum CycleSymptom { cramps, headache, mood, fatigue }

enum CycleContext { pregnancy, postpartum, hormonalChange, procedure, other }

DateTime cycleDate(DateTime value) =>
    DateTime(value.year, value.month, value.day);

String cycleDateKey(DateTime value) {
  final date = cycleDate(value);
  return '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}

DateTime parseCycleDate(String value) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null || value.length != 10) {
    throw const FormatException('经期日期格式无效');
  }
  return cycleDate(parsed);
}

class CyclePeriodRecord {
  const CyclePeriodRecord({
    required this.id,
    required this.startDate,
    required this.endDate,
    required this.excludedFromPrediction,
    required this.context,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final DateTime startDate;
  final DateTime? endDate;
  final bool excludedFromPrediction;
  final CycleContext? context;
  final DateTime createdAt;
  final DateTime updatedAt;

  int? get durationDays => endDate == null
      ? null
      : cycleDate(endDate!).difference(cycleDate(startDate)).inDays + 1;

  bool contains(DateTime value, {DateTime? ongoingEnd}) {
    final date = cycleDate(value);
    final end = endDate == null
        ? cycleDate(ongoingEnd ?? DateTime.now())
        : cycleDate(endDate!);
    return !date.isBefore(cycleDate(startDate)) && !date.isAfter(end);
  }
}

class CyclePeriodDraft {
  const CyclePeriodDraft({
    required this.startDate,
    this.endDate,
    this.excludedFromPrediction = false,
    this.context,
  });

  final DateTime startDate;
  final DateTime? endDate;
  final bool excludedFromPrediction;
  final CycleContext? context;

  CyclePeriodDraft normalized() => CyclePeriodDraft(
    startDate: cycleDate(startDate),
    endDate: endDate == null ? null : cycleDate(endDate!),
    excludedFromPrediction: excludedFromPrediction,
    context: context,
  );

  void validate() {
    final start = cycleDate(startDate);
    final end = endDate == null ? null : cycleDate(endDate!);
    if (end != null && end.isBefore(start)) {
      throw const FormatException('结束日期不能早于开始日期');
    }
  }
}

class CycleDailyLog {
  const CycleDailyLog({
    required this.date,
    required this.periodId,
    required this.bleedingLevel,
    required this.spotting,
    required this.symptoms,
    required this.updatedAt,
  });

  final DateTime date;
  final String periodId;
  final CycleFlowLevel? bleedingLevel;
  final bool spotting;
  final Set<CycleSymptom> symptoms;
  final DateTime updatedAt;
}

class CycleDailyLogDraft {
  const CycleDailyLogDraft({
    required this.date,
    this.bleedingLevel,
    this.spotting = false,
    this.symptoms = const {},
  });

  final DateTime date;
  final CycleFlowLevel? bleedingLevel;
  final bool spotting;
  final Set<CycleSymptom> symptoms;

  bool get isEmpty => bleedingLevel == null && !spotting && symptoms.isEmpty;

  CycleDailyLogDraft normalized() => CycleDailyLogDraft(
    date: cycleDate(date),
    bleedingLevel: bleedingLevel,
    spotting: spotting,
    symptoms: Set.unmodifiable(symptoms),
  );
}

class CycleTrackingSettings {
  const CycleTrackingSettings({
    required this.enabled,
    required this.forecastHorizon,
    required this.updatedAt,
  });

  final bool enabled;
  final int forecastHorizon;
  final DateTime updatedAt;

  CycleTrackingSettings copyWith({
    bool? enabled,
    int? forecastHorizon,
    DateTime? updatedAt,
  }) => CycleTrackingSettings(
    enabled: enabled ?? this.enabled,
    forecastHorizon: forecastHorizon ?? this.forecastHorizon,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}
