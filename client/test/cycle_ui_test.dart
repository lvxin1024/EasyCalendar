import 'package:easy_calendar/application/cycle_controller.dart';
import 'package:easy_calendar/data/cycle_repository.dart';
import 'package:easy_calendar/domain/cycle_record.dart';
import 'package:easy_calendar/features/cycle/cycle_record_sheet.dart';
import 'package:easy_calendar/features/cycle/cycle_settings_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('settings switch persists cycle tracking locally', (
    tester,
  ) async {
    final fixture = await _fixture();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CycleSettingsSection(
            controller: fixture.controller,
            onOpenSummary: () {},
          ),
        ),
      ),
    );

    expect(fixture.controller.enabled, isFalse);
    await tester.tap(find.byType(Switch).first);
    await tester.pump();
    await tester.runAsync(() async {
      while (fixture.controller.mutating) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump(const Duration(milliseconds: 300));

    expect(fixture.controller.enabled, isTrue);
    expect((await fixture.repository.loadSettings()).enabled, isTrue);
  });

  testWidgets('record editor saves an ongoing period', (tester) async {
    final fixture = await _fixture();
    await fixture.controller.setEnabled(true);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () => showCycleRecordEditor(
                context,
                controller: fixture.controller,
                initialDate: DateTime(2026, 8, 31),
              ),
              child: const Text('打开记录'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开记录'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('记录经期'), findsOneWidget);

    await tester.tap(find.text('仍在进行中'));
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.runAsync(() async {
      while (fixture.controller.mutating) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump(const Duration(milliseconds: 400));

    expect(fixture.controller.periods, hasLength(1));
    expect(fixture.controller.periods.single.endDate, isNull);
  });
}

Future<({_MemoryCycleRepository repository, CycleController controller})>
_fixture() async {
  final repository = _MemoryCycleRepository();
  final controller = CycleController(
    repository: repository,
    clock: () => DateTime(2026, 8, 31, 12),
  );
  await controller.initialize();
  return (repository: repository, controller: controller);
}

class _MemoryCycleRepository implements CycleRepository {
  final List<CyclePeriodRecord> _periods = [];
  CycleTrackingSettings _settings = CycleTrackingSettings(
    enabled: false,
    forecastHorizon: 1,
    updatedAt: DateTime(2026, 8, 31),
  );

  @override
  Future<CyclePeriodRecord> createPeriod(
    CyclePeriodDraft draft, {
    List<CycleDailyLogDraft> dailyLogs = const [],
  }) async {
    final record = CyclePeriodRecord(
      id: 'period_1',
      startDate: cycleDate(draft.startDate),
      endDate: draft.endDate == null ? null : cycleDate(draft.endDate!),
      excludedFromPrediction: draft.excludedFromPrediction,
      context: draft.context,
      createdAt: DateTime(2026, 8, 31),
      updatedAt: DateTime(2026, 8, 31),
    );
    _periods.add(record);
    return record;
  }

  @override
  Future<void> deletePeriod(String periodId) async {
    _periods.removeWhere((period) => period.id == periodId);
  }

  @override
  Future<List<CycleDailyLog>> listDailyLogs({String? periodId}) async =>
      const [];

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
  }) {
    throw UnimplementedError();
  }
}
