import 'package:easy_calendar/application/cycle_controller.dart';
import 'package:easy_calendar/data/cycle_repository.dart';
import 'package:easy_calendar/domain/cycle_prediction.dart';
import 'package:easy_calendar/domain/cycle_record.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 8, 31, 12);

  test('loads local records and derives a prediction', () async {
    final repository = _MemoryCycleRepository(
      periods: [
        _period('a', DateTime(2026, 6, 1), DateTime(2026, 6, 5)),
        _period('b', DateTime(2026, 6, 29), DateTime(2026, 7, 3)),
        _period('c', DateTime(2026, 7, 27), DateTime(2026, 7, 31)),
      ],
    );
    final controller = CycleController(
      repository: repository,
      clock: () => now,
    );

    await controller.initialize();

    expect(controller.initialized, isTrue);
    expect(controller.error, isNull);
    expect(controller.prediction?.predictedStart, DateTime(2026, 8, 24));
    expect(
      controller.stateForDate(DateTime(2026, 8, 24))?.kind,
      CycleDayKind.predicted,
    );
  });

  test('recorded days take priority and ongoing periods stop today', () async {
    final repository = _MemoryCycleRepository(
      periods: [
        _period('a', DateTime(2026, 7, 6), DateTime(2026, 7, 10)),
        _period('b', DateTime(2026, 8, 3), DateTime(2026, 8, 7)),
        _period('c', DateTime(2026, 8, 31), null),
      ],
    );
    final controller = CycleController(
      repository: repository,
      clock: () => now,
    );
    await controller.initialize();

    final today = controller.stateForDate(now);
    expect(today?.kind, CycleDayKind.recorded);
    expect(today?.isStart, isTrue);
    expect(today?.isEnd, isTrue);
    expect(controller.stateForDate(DateTime(2026, 9, 1)), isNull);
  });

  test('mutations refresh prediction and disabling hides day states', () async {
    final repository = _MemoryCycleRepository(
      periods: [
        _period('a', DateTime(2026, 6, 1), DateTime(2026, 6, 5)),
        _period('b', DateTime(2026, 6, 29), DateTime(2026, 7, 3)),
      ],
    );
    final controller = CycleController(
      repository: repository,
      clock: () => now,
    );
    await controller.initialize();
    expect(controller.prediction, isNull);

    await controller.createPeriod(
      CyclePeriodDraft(
        startDate: DateTime(2026, 7, 27),
        endDate: DateTime(2026, 7, 31),
      ),
    );
    expect(controller.prediction, isNotNull);

    await controller.setEnabled(false);
    expect(controller.stateForDate(DateTime(2026, 8, 24)), isNull);
  });
}

class _MemoryCycleRepository implements CycleRepository {
  _MemoryCycleRepository({List<CyclePeriodRecord> periods = const []})
    : _periods = [...periods];

  final List<CyclePeriodRecord> _periods;
  final List<CycleDailyLog> _logs = [];
  CycleTrackingSettings _settings = CycleTrackingSettings(
    enabled: true,
    forecastHorizon: 1,
    updatedAt: DateTime(2026, 1, 1),
  );
  var _nextId = 1;

  @override
  Future<CyclePeriodRecord> createPeriod(
    CyclePeriodDraft draft, {
    List<CycleDailyLogDraft> dailyLogs = const [],
  }) async {
    final now = DateTime(2026, 8, 31);
    final record = CyclePeriodRecord(
      id: 'new_${_nextId++}',
      startDate: cycleDate(draft.startDate),
      endDate: draft.endDate == null ? null : cycleDate(draft.endDate!),
      excludedFromPrediction: draft.excludedFromPrediction,
      context: draft.context,
      createdAt: now,
      updatedAt: now,
    );
    _periods.add(record);
    return record;
  }

  @override
  Future<void> deletePeriod(String periodId) async {
    _periods.removeWhere((period) => period.id == periodId);
  }

  @override
  Future<List<CycleDailyLog>> listDailyLogs({String? periodId}) async => _logs
      .where((log) => periodId == null || log.periodId == periodId)
      .toList(growable: false);

  @override
  Future<List<CyclePeriodRecord>> listPeriods() async => [..._periods];

  @override
  Future<CycleTrackingSettings> loadSettings() async => _settings;

  @override
  Future<void> saveSettings(CycleTrackingSettings settings) async {
    _settings = settings;
  }

  @override
  Future<CyclePeriodRecord> updatePeriod(
    CyclePeriodRecord current,
    CyclePeriodDraft draft, {
    List<CycleDailyLogDraft> dailyLogs = const [],
  }) async {
    final index = _periods.indexWhere((period) => period.id == current.id);
    final updated = CyclePeriodRecord(
      id: current.id,
      startDate: cycleDate(draft.startDate),
      endDate: draft.endDate == null ? null : cycleDate(draft.endDate!),
      excludedFromPrediction: draft.excludedFromPrediction,
      context: draft.context,
      createdAt: current.createdAt,
      updatedAt: DateTime(2026, 8, 31),
    );
    _periods[index] = updated;
    return updated;
  }
}

CyclePeriodRecord _period(String id, DateTime start, DateTime? end) =>
    CyclePeriodRecord(
      id: id,
      startDate: start,
      endDate: end,
      excludedFromPrediction: false,
      context: null,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
