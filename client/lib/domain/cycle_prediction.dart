enum CyclePredictionConfidence { insufficient, low, medium, high }

class CyclePrediction {
  const CyclePrediction({
    required this.algorithmVersion,
    required this.generatedAt,
    required this.sampleSize,
    required this.predictedStart,
    required this.predictedEnd,
    required this.possibleStart,
    required this.possibleEnd,
    required this.typicalCycleLength,
    required this.predictedDuration,
    required this.marginDays,
    required this.confidence,
    required this.suspectedMissedRecord,
  });

  final String algorithmVersion;
  final DateTime generatedAt;
  final int sampleSize;
  final DateTime predictedStart;
  final DateTime? predictedEnd;
  final DateTime possibleStart;
  final DateTime possibleEnd;
  final int typicalCycleLength;
  final int? predictedDuration;
  final int marginDays;
  final CyclePredictionConfidence confidence;
  final bool suspectedMissedRecord;
}

enum CycleDayKind { recorded, predicted }

class CycleDayState {
  const CycleDayState({
    required this.kind,
    required this.isStart,
    required this.isEnd,
    required this.isCenter,
    this.periodId,
    this.dayNumber,
    this.excludedFromPrediction = false,
  });

  final CycleDayKind kind;
  final bool isStart;
  final bool isEnd;
  final bool isCenter;
  final String? periodId;
  final int? dayNumber;
  final bool excludedFromPrediction;
}
