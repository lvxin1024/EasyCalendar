// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';

import '../data/cycle_repository.dart';
import '../domain/cycle_prediction.dart';
import '../domain/cycle_predictor.dart';
import '../domain/cycle_record.dart';

class CycleController extends ChangeNotifier {
  CycleController({
    required CycleRepository repository,
    CyclePredictor predictor = const CyclePredictor(),
    DateTime Function()? clock,
  }) : _repository = repository,
       _predictor = predictor,
       _clock = clock ?? DateTime.now;

  final CycleRepository _repository;
  final CyclePredictor _predictor;
  final DateTime Function() _clock;

  CycleTrackingSettings _settings = CycleTrackingSettings(
    enabled: false,
    forecastHorizon: 1,
    updatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  );
  List<CyclePeriodRecord> _periods = const [];
  List<CycleDailyLog> _dailyLogs = const [];
  CyclePrediction? _prediction;
  bool _loading = true;
  bool _initialized = false;
  bool _mutating = false;
  Object? _error;

  CycleTrackingSettings get settings => _settings;
  bool get enabled => _settings.enabled;
  List<CyclePeriodRecord> get periods => List.unmodifiable(_periods);
  List<CycleDailyLog> get dailyLogs => List.unmodifiable(_dailyLogs);
  CyclePrediction? get prediction => _prediction;
  bool get loading => _loading;
  bool get initialized => _initialized;
  bool get mutating => _mutating;
  Object? get error => _error;

  Future<void> initialize() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      await _load();
      _initialized = true;
    } catch (error) {
      _error = error;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    try {
      await _load();
      _initialized = true;
      _error = null;
    } catch (error) {
      _error = error;
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  Future<void> setEnabled(bool enabled) async {
    if (enabled == _settings.enabled) return;
    final settings = _settings.copyWith(
      enabled: enabled,
      updatedAt: _clock(),
      version: _settings.version + 1,
    );
    await _runMutation(() async {
      await _repository.saveSettings(settings);
      _settings = settings;
    });
  }

  Future<CyclePeriodRecord> createPeriod(
    CyclePeriodDraft draft, {
    List<CycleDailyLogDraft> dailyLogs = const [],
  }) async {
    late CyclePeriodRecord created;
    await _runMutation(() async {
      created = await _repository.createPeriod(draft, dailyLogs: dailyLogs);
      await _reloadRecords();
    });
    return created;
  }

  Future<CyclePeriodRecord> updatePeriod(
    CyclePeriodRecord current,
    CyclePeriodDraft draft, {
    List<CycleDailyLogDraft> dailyLogs = const [],
  }) async {
    late CyclePeriodRecord updated;
    await _runMutation(() async {
      updated = await _repository.updatePeriod(
        current,
        draft,
        dailyLogs: dailyLogs,
      );
      await _reloadRecords();
    });
    return updated;
  }

  Future<void> deletePeriod(String periodId) => _runMutation(() async {
    await _repository.deletePeriod(periodId);
    await _reloadRecords();
  });

  List<CycleDailyLog> dailyLogsForPeriod(String periodId) => _dailyLogs
      .where((log) => log.periodId == periodId)
      .toList(growable: false);

  CycleDayState? stateForDate(DateTime value) {
    if (!enabled) return null;
    final date = cycleDate(value);
    final today = cycleDate(_clock());
    for (final period in _periods.reversed) {
      if (!period.contains(date, ongoingEnd: today)) continue;
      final end = period.endDate == null ? today : cycleDate(period.endDate!);
      return CycleDayState(
        kind: CycleDayKind.recorded,
        isStart: date == cycleDate(period.startDate),
        isEnd: date == end,
        isCenter: false,
        periodId: period.id,
        dayNumber: date.difference(cycleDate(period.startDate)).inDays + 1,
        excludedFromPrediction: period.excludedFromPrediction,
      );
    }

    final forecast = _prediction;
    if (forecast == null) return null;
    final start = cycleDate(forecast.predictedStart);
    final end = cycleDate(forecast.predictedEnd ?? forecast.predictedStart);
    if (date.isBefore(start) || date.isAfter(end)) return null;
    return CycleDayState(
      kind: CycleDayKind.predicted,
      isStart: date == start,
      isEnd: date == end,
      isCenter: date == start,
      dayNumber: date.difference(start).inDays + 1,
    );
  }

  Map<DateTime, CycleDayState> statesBetween(DateTime start, DateTime end) {
    final first = cycleDate(start);
    final last = cycleDate(end);
    if (last.isBefore(first)) {
      throw const FormatException('结束日期不能早于开始日期');
    }
    final states = <DateTime, CycleDayState>{};
    for (
      var date = first;
      !date.isAfter(last);
      date = date.add(const Duration(days: 1))
    ) {
      final state = stateForDate(date);
      if (state != null) states[date] = state;
    }
    return Map.unmodifiable(states);
  }

  Future<void> _load() async {
    _settings = await _repository.loadSettings();
    await _reloadRecords();
  }

  Future<void> _reloadRecords() async {
    _periods = await _repository.listPeriods();
    _dailyLogs = await _repository.listDailyLogs();
    _prediction = _predictor.predict(_periods, generatedAt: _clock());
  }

  Future<void> _runMutation(Future<void> Function() operation) async {
    if (_mutating) throw StateError('经期数据正在保存');
    _mutating = true;
    _error = null;
    notifyListeners();
    try {
      await operation();
    } catch (error) {
      _error = error;
      rethrow;
    } finally {
      _mutating = false;
      notifyListeners();
    }
  }
}
