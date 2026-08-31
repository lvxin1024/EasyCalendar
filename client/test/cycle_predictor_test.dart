import 'package:easy_calendar/domain/cycle_prediction.dart';
import 'package:easy_calendar/domain/cycle_predictor.dart';
import 'package:easy_calendar/domain/cycle_record.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const predictor = CyclePredictor();

  test('requires at least two valid cycle intervals', () {
    expect(predictor.predict([_period(2026, 1, 1)]), isNull);
    expect(
      predictor.predict([_period(2026, 1, 1), _period(2026, 1, 29)]),
      isNull,
    );
  });

  test('predicts next start and duration using medians', () {
    final result = predictor.predict([
      _period(2026, 1, 1, duration: 5),
      _period(2026, 1, 29, duration: 4),
      _period(2026, 2, 27, duration: 5),
      _period(2026, 3, 27, duration: 6),
    ], generatedAt: DateTime.utc(2026, 4, 1));

    expect(result, isNotNull);
    expect(result!.typicalCycleLength, 28);
    expect(result.predictedStart, DateTime(2026, 4, 24));
    expect(result.predictedDuration, 5);
    expect(result.predictedEnd, DateTime(2026, 4, 28));
    expect(result.marginDays, 2);
    expect(result.confidence, CyclePredictionConfidence.medium);
  });

  test('does not bridge an excluded record into a synthetic long interval', () {
    final result = predictor.predict([
      _period(2026, 1, 1),
      _period(2026, 1, 29),
      _period(2026, 2, 26, excluded: true),
      _period(2026, 3, 26),
      _period(2026, 4, 23),
    ]);

    expect(result, isNotNull);
    expect(result!.sampleSize, 2);
    expect(result.typicalCycleLength, 28);
  });

  test('flags a near-double interval as a possible missed record', () {
    final result = predictor.predict([
      _period(2026, 1, 1),
      _period(2026, 1, 29),
      _period(2026, 2, 26),
      _period(2026, 4, 23),
      _period(2026, 5, 21),
    ]);

    expect(result, isNotNull);
    expect(result!.typicalCycleLength, 28);
    expect(result.suspectedMissedRecord, isTrue);
  });

  test('limits prediction input to the six most recent intervals', () {
    final records = <CyclePeriodRecord>[];
    var start = DateTime(2025, 1, 1);
    records.add(_periodAt(start));
    for (final length in [45, 45, 28, 29, 28, 29, 28, 29]) {
      start = start.add(Duration(days: length));
      records.add(_periodAt(start));
    }

    final result = predictor.predict(records);

    expect(result, isNotNull);
    expect(result!.sampleSize, 6);
    expect(result.typicalCycleLength, 29);
  });
}

CyclePeriodRecord _period(
  int year,
  int month,
  int day, {
  int? duration,
  bool excluded = false,
}) => _periodAt(
  DateTime(year, month, day),
  duration: duration,
  excluded: excluded,
);

CyclePeriodRecord _periodAt(
  DateTime start, {
  int? duration,
  bool excluded = false,
}) => CyclePeriodRecord(
  id: start.toIso8601String(),
  startDate: start,
  endDate: duration == null ? null : start.add(Duration(days: duration - 1)),
  excludedFromPrediction: excluded,
  context: null,
  createdAt: DateTime.utc(2025),
  updatedAt: DateTime.utc(2025),
);
