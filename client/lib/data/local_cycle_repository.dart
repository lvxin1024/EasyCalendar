// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../domain/cycle_record.dart';
import 'cycle_repository.dart';

class LocalCycleRepository implements CycleRepository {
  LocalCycleRepository({
    required Future<Database> Function() databaseProvider,
    Uuid? uuid,
    DateTime Function()? clock,
  }) : _databaseProvider = databaseProvider,
       _uuid = uuid ?? Uuid(),
       _clock = clock ?? DateTime.now;

  final Future<Database> Function() _databaseProvider;
  final Uuid _uuid;
  final DateTime Function() _clock;

  @override
  Future<CycleTrackingSettings> loadSettings() async {
    final database = await _databaseProvider();
    final rows = await database.query(
      'cycle_settings',
      where: 'id = 1',
      limit: 1,
    );
    if (rows.isEmpty) {
      final settings = CycleTrackingSettings(
        enabled: false,
        forecastHorizon: 1,
        updatedAt: _clock(),
      );
      await saveSettings(settings);
      return settings;
    }
    final row = rows.single;
    return CycleTrackingSettings(
      enabled: row['enabled'] == 1,
      forecastHorizon: (row['forecast_horizon'] as int).clamp(1, 3),
      updatedAt: DateTime.parse(row['updated_at'] as String),
    );
  }

  @override
  Future<void> saveSettings(CycleTrackingSettings settings) async {
    final database = await _databaseProvider();
    await database.insert('cycle_settings', {
      'id': 1,
      'enabled': settings.enabled ? 1 : 0,
      'forecast_horizon': settings.forecastHorizon.clamp(1, 3),
      'updated_at': settings.updatedAt.toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<List<CyclePeriodRecord>> listPeriods() async {
    final database = await _databaseProvider();
    final rows = await database.query(
      'cycle_periods',
      orderBy: 'start_date ASC, id ASC',
    );
    return rows.map(_periodFromRow).toList(growable: false);
  }

  @override
  Future<List<CycleDailyLog>> listDailyLogs({String? periodId}) async {
    final database = await _databaseProvider();
    final rows = await database.query(
      'cycle_daily_logs',
      where: periodId == null ? null : 'period_id = ?',
      whereArgs: periodId == null ? null : [periodId],
      orderBy: 'date ASC',
    );
    return rows.map(_dailyLogFromRow).toList(growable: false);
  }

  @override
  Future<CyclePeriodRecord> createPeriod(
    CyclePeriodDraft draft, {
    List<CycleDailyLogDraft> dailyLogs = const [],
  }) async {
    final normalized = draft.normalized();
    normalized.validate();
    final database = await _databaseProvider();
    final now = _clock().toUtc();
    final record = CyclePeriodRecord(
      id: _uuid.v4(),
      startDate: normalized.startDate,
      endDate: normalized.endDate,
      excludedFromPrediction: normalized.excludedFromPrediction,
      context: normalized.context,
      createdAt: now,
      updatedAt: now,
    );
    await database.transaction((transaction) async {
      await _ensureNoOverlap(transaction, record);
      await transaction.insert('cycle_periods', _periodToRow(record));
      await _replaceDailyLogs(transaction, record, dailyLogs);
    });
    return record;
  }

  @override
  Future<CyclePeriodRecord> updatePeriod(
    CyclePeriodRecord current,
    CyclePeriodDraft draft, {
    List<CycleDailyLogDraft> dailyLogs = const [],
  }) async {
    final normalized = draft.normalized();
    normalized.validate();
    final database = await _databaseProvider();
    final record = CyclePeriodRecord(
      id: current.id,
      startDate: normalized.startDate,
      endDate: normalized.endDate,
      excludedFromPrediction: normalized.excludedFromPrediction,
      context: normalized.context,
      createdAt: current.createdAt,
      updatedAt: _clock().toUtc(),
    );
    await database.transaction((transaction) async {
      await _ensureNoOverlap(transaction, record, excludingId: current.id);
      final count = await transaction.update(
        'cycle_periods',
        _periodToRow(record),
        where: 'id = ?',
        whereArgs: [current.id],
      );
      if (count != 1) {
        throw const CycleRepositoryConflict('经期记录不存在');
      }
      await _replaceDailyLogs(transaction, record, dailyLogs);
    });
    return record;
  }

  @override
  Future<void> deletePeriod(String periodId) async {
    final database = await _databaseProvider();
    final count = await database.delete(
      'cycle_periods',
      where: 'id = ?',
      whereArgs: [periodId],
    );
    if (count != 1) throw const CycleRepositoryConflict('经期记录不存在');
  }

  Future<void> _ensureNoOverlap(
    DatabaseExecutor database,
    CyclePeriodRecord candidate, {
    String? excludingId,
  }) async {
    final rows = await database.query(
      'cycle_periods',
      where: excludingId == null ? null : 'id != ?',
      whereArgs: excludingId == null ? null : [excludingId],
    );
    for (final row in rows) {
      final existing = _periodFromRow(row);
      final candidateEnd = candidate.endDate ?? DateTime(9999, 12, 31);
      final existingEnd = existing.endDate ?? DateTime(9999, 12, 31);
      if (!candidateEnd.isBefore(existing.startDate) &&
          !existingEnd.isBefore(candidate.startDate)) {
        throw const CycleRepositoryConflict('经期日期与已有记录重叠');
      }
    }
  }

  Future<void> _replaceDailyLogs(
    DatabaseExecutor database,
    CyclePeriodRecord period,
    List<CycleDailyLogDraft> drafts,
  ) async {
    await database.delete(
      'cycle_daily_logs',
      where: 'period_id = ?',
      whereArgs: [period.id],
    );
    for (final raw in drafts) {
      final draft = raw.normalized();
      if (draft.isEmpty) continue;
      final end = period.endDate ?? cycleDate(_clock());
      if (draft.date.isBefore(period.startDate) || draft.date.isAfter(end)) {
        throw const CycleRepositoryConflict('每日记录必须位于本次经期范围内');
      }
      await database.insert('cycle_daily_logs', {
        'date': cycleDateKey(draft.date),
        'period_id': period.id,
        'bleeding_level': draft.bleedingLevel?.name,
        'spotting': draft.spotting ? 1 : 0,
        'symptoms_json': jsonEncode(
          draft.symptoms.map((symptom) => symptom.name).toList()..sort(),
        ),
        'updated_at': _clock().toUtc().toIso8601String(),
      });
    }
  }

  static CyclePeriodRecord _periodFromRow(Map<String, Object?> row) =>
      CyclePeriodRecord(
        id: row['id'] as String,
        startDate: parseCycleDate(row['start_date'] as String),
        endDate: row['end_date'] == null
            ? null
            : parseCycleDate(row['end_date'] as String),
        excludedFromPrediction: row['excluded_from_prediction'] == 1,
        context: _enumOrNull(CycleContext.values, row['context']),
        createdAt: DateTime.parse(row['created_at'] as String),
        updatedAt: DateTime.parse(row['updated_at'] as String),
      );

  static Map<String, Object?> _periodToRow(CyclePeriodRecord record) => {
    'id': record.id,
    'start_date': cycleDateKey(record.startDate),
    'end_date': record.endDate == null ? null : cycleDateKey(record.endDate!),
    'excluded_from_prediction': record.excludedFromPrediction ? 1 : 0,
    'context': record.context?.name,
    'created_at': record.createdAt.toUtc().toIso8601String(),
    'updated_at': record.updatedAt.toUtc().toIso8601String(),
  };

  static CycleDailyLog _dailyLogFromRow(Map<String, Object?> row) {
    final decoded = jsonDecode(row['symptoms_json'] as String);
    final symptoms = <CycleSymptom>{};
    if (decoded is List) {
      for (final value in decoded) {
        final symptom = _enumOrNull(CycleSymptom.values, value);
        if (symptom != null) symptoms.add(symptom);
      }
    }
    return CycleDailyLog(
      date: parseCycleDate(row['date'] as String),
      periodId: row['period_id'] as String,
      bleedingLevel: _enumOrNull(CycleFlowLevel.values, row['bleeding_level']),
      spotting: row['spotting'] == 1,
      symptoms: Set.unmodifiable(symptoms),
      updatedAt: DateTime.parse(row['updated_at'] as String),
    );
  }

  static T? _enumOrNull<T extends Enum>(List<T> values, Object? name) {
    if (name is! String) return null;
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }
}
