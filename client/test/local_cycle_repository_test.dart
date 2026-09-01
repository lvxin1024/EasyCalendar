import 'package:easy_calendar/data/local_cycle_repository.dart';
import 'package:easy_calendar/data/local_database_schema.dart';
import 'package:easy_calendar/domain/cycle_record.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database database;
  late LocalCycleRepository repository;
  final syncEntities = <String>[];
  final clock = DateTime.utc(2026, 8, 31, 12);

  setUp(() async {
    syncEntities.clear();
    sqfliteFfiInit();
    database = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: LocalDatabaseSchema.version,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: LocalDatabaseSchema.create,
      ),
    );
    repository = LocalCycleRepository(
      databaseProvider: () async => database,
      clock: () => clock,
      syncOutboxWriter:
          (
            transaction,
            entityType,
            entityId,
            operation,
            version,
            updatedAt,
            payload,
          ) async {
            syncEntities.add('$entityType:$entityId:$operation:$version');
          },
    );
  });

  tearDown(() => database.close());

  test('settings default to disabled and persist locally', () async {
    final initial = await repository.loadSettings();
    expect(initial.enabled, isFalse);

    await repository.saveSettings(initial.copyWith(enabled: true, version: 2));

    expect((await repository.loadSettings()).enabled, isTrue);
    expect(syncEntities.single, contains('cycle_settings:singleton:update:2'));
  });

  test('creates periods and replaces optional daily logs atomically', () async {
    final period = await repository.createPeriod(
      CyclePeriodDraft(
        startDate: DateTime(2026, 8, 1),
        endDate: DateTime(2026, 8, 5),
      ),
      dailyLogs: [
        CycleDailyLogDraft(
          date: DateTime(2026, 8, 1),
          bleedingLevel: CycleFlowLevel.medium,
          symptoms: const {CycleSymptom.cramps},
        ),
      ],
    );

    expect((await repository.listPeriods()).single.id, period.id);
    final logs = await repository.listDailyLogs(periodId: period.id);
    expect(logs.single.bleedingLevel, CycleFlowLevel.medium);
    expect(logs.single.symptoms, {CycleSymptom.cramps});

    await repository.updatePeriod(
      period,
      CyclePeriodDraft(
        startDate: DateTime(2026, 8, 1),
        endDate: DateTime(2026, 8, 4),
      ),
      dailyLogs: [
        CycleDailyLogDraft(date: DateTime(2026, 8, 2), spotting: true),
      ],
    );

    final updatedLogs = await repository.listDailyLogs(periodId: period.id);
    expect(updatedLogs.single.date, DateTime(2026, 8, 2));
    expect(updatedLogs.single.spotting, isTrue);
    expect(syncEntities.map((value) => value.split(':').first), [
      'cycle_period',
      'cycle_period',
    ]);
  });

  test('rejects overlapping periods and cascades daily log deletion', () async {
    final period = await repository.createPeriod(
      CyclePeriodDraft(
        startDate: DateTime(2026, 8, 1),
        endDate: DateTime(2026, 8, 5),
      ),
      dailyLogs: [
        CycleDailyLogDraft(
          date: DateTime(2026, 8, 1),
          bleedingLevel: CycleFlowLevel.light,
        ),
      ],
    );

    expect(
      () => repository.createPeriod(
        CyclePeriodDraft(
          startDate: DateTime(2026, 8, 4),
          endDate: DateTime(2026, 8, 8),
        ),
      ),
      throwsA(isA<Exception>()),
    );

    await repository.deletePeriod(period.id);
    expect(await repository.listDailyLogs(periodId: period.id), isEmpty);
    expect(
      (await database.query('cycle_periods')).single['deleted_at'],
      isNotNull,
    );
    expect(syncEntities.last, contains(':delete:2'));
  });
}
