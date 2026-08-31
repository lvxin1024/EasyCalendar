import 'dart:math' as math;

import 'cycle_prediction.dart';
import 'cycle_record.dart';

class CyclePredictor {
  const CyclePredictor();

  static const algorithmVersion = 'median-mad-v1';
  static const maximumIntervals = 6;

  CyclePrediction? predict(
    Iterable<CyclePeriodRecord> records, {
    DateTime? generatedAt,
  }) {
    final sorted = records.toList(growable: false)
      ..sort((left, right) => left.startDate.compareTo(right.startDate));
    final intervals = <int>[];
    for (var index = 1; index < sorted.length; index++) {
      final previous = sorted[index - 1];
      final current = sorted[index];
      if (previous.excludedFromPrediction || current.excludedFromPrediction) {
        continue;
      }
      final length = cycleDate(
        current.startDate,
      ).difference(cycleDate(previous.startDate)).inDays;
      if (length > 0) intervals.add(length);
    }
    if (intervals.length < 2) return null;

    final recentIntervals = intervals.length <= maximumIntervals
        ? intervals
        : intervals.sublist(intervals.length - maximumIntervals);
    final typicalLength = _median(recentIntervals).round();
    final mad = _median(
      recentIntervals
          .map((length) => (length - typicalLength).abs())
          .toList(growable: false),
    );
    final robustMargin = math.max(2, (1.4826 * mad).ceil());
    final backtestMargin = recentIntervals.length < maximumIntervals
        ? 0
        : _backtestMargin(recentIntervals);
    final margin = math.max(robustMargin, backtestMargin);

    final included = sorted
        .where((record) => !record.excludedFromPrediction)
        .toList(growable: false);
    if (included.isEmpty) return null;
    final lastStart = cycleDate(included.last.startDate);
    final predictedStart = lastStart.add(Duration(days: typicalLength));
    final durations = included
        .map((record) => record.durationDays)
        .whereType<int>()
        .where((duration) => duration > 0)
        .toList(growable: false);
    final recentDurations = durations.length <= maximumIntervals
        ? durations
        : durations.sublist(durations.length - maximumIntervals);
    final predictedDuration = recentDurations.isEmpty
        ? null
        : _median(recentDurations).round();

    return CyclePrediction(
      algorithmVersion: algorithmVersion,
      generatedAt: generatedAt ?? DateTime.now(),
      sampleSize: recentIntervals.length,
      predictedStart: predictedStart,
      predictedEnd: predictedDuration == null
          ? null
          : predictedStart.add(Duration(days: predictedDuration - 1)),
      possibleStart: predictedStart.subtract(Duration(days: margin)),
      possibleEnd: predictedStart.add(Duration(days: margin)),
      typicalCycleLength: typicalLength,
      predictedDuration: predictedDuration,
      marginDays: margin,
      confidence: _confidence(recentIntervals.length, margin),
      suspectedMissedRecord:
          recentIntervals.length >= 3 &&
          recentIntervals.any(
            (length) =>
                (length - typicalLength * 2).abs() <= math.max(3, margin),
          ),
    );
  }

  static int _backtestMargin(List<int> intervals) {
    final errors = <int>[];
    for (var index = 2; index < intervals.length; index++) {
      final predicted = _median(intervals.sublist(0, index)).round();
      errors.add((intervals[index] - predicted).abs());
    }
    if (errors.isEmpty) return 0;
    errors.sort();
    final percentileIndex = ((errors.length - 1) * 0.8).ceil();
    return errors[percentileIndex];
  }

  static CyclePredictionConfidence _confidence(int samples, int margin) {
    if (samples < 2) return CyclePredictionConfidence.insufficient;
    if (samples == 2 || margin > 7) return CyclePredictionConfidence.low;
    if (samples < 6 || margin > 3) return CyclePredictionConfidence.medium;
    return CyclePredictionConfidence.high;
  }

  static double _median(List<int> values) {
    if (values.isEmpty) throw StateError('Median requires at least one value');
    final sorted = [...values]..sort();
    final middle = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[middle].toDouble();
    return (sorted[middle - 1] + sorted[middle]) / 2;
  }
}
