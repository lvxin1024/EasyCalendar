import '../domain/cycle_record.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

typedef CycleSyncOutboxWriter =
    Future<void> Function(
      Transaction transaction,
      String entityType,
      String entityId,
      String operation,
      int version,
      DateTime updatedAt,
      Map<String, Object?> payload,
    );

abstract interface class CycleRepository {
  Future<CycleTrackingSettings> loadSettings();

  Future<void> saveSettings(CycleTrackingSettings settings);

  Future<List<CyclePeriodRecord>> listPeriods();

  Future<List<CycleDailyLog>> listDailyLogs({String? periodId});

  Future<CyclePeriodRecord> createPeriod(
    CyclePeriodDraft draft, {
    List<CycleDailyLogDraft> dailyLogs = const [],
  });

  Future<CyclePeriodRecord> updatePeriod(
    CyclePeriodRecord current,
    CyclePeriodDraft draft, {
    List<CycleDailyLogDraft> dailyLogs = const [],
  });

  Future<void> deletePeriod(String periodId);
}

class CycleRepositoryConflict implements Exception {
  const CycleRepositoryConflict(this.message);

  final String message;

  @override
  String toString() => message;
}
