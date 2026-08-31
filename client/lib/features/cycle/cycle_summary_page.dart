import 'package:flutter/material.dart';

import '../../application/cycle_controller.dart';
import '../../domain/cycle_prediction.dart';
import '../../domain/cycle_record.dart';
import 'cycle_record_sheet.dart';

class CycleSummaryPage extends StatelessWidget {
  const CycleSummaryPage({super.key, required this.controller});

  final CycleController controller;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('周期概览')),
    body: AnimatedBuilder(
      animation: controller,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 96),
        children: [
          _PredictionSummary(prediction: controller.prediction),
          const SizedBox(height: 18),
          Text('经期记录', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          if (controller.periods.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Text('尚无记录。至少记录 3 次开始日期后，才能试算下一次经期。'),
            )
          else
            for (final period in controller.periods.reversed)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.water_drop_outlined),
                title: Text(_periodLabel(period)),
                subtitle: Text(_periodSubtitle(period)),
                trailing: const Icon(Icons.edit_outlined),
                onTap: () => showCycleRecordEditor(
                  context,
                  controller: controller,
                  current: period,
                ),
              ),
          const Divider(height: 28),
          Text(
            '预测仅基于你的历史开始日期，可能受漏记、怀孕、产后、激素变化等影响。'
            '它不是医疗诊断，也不能用于推算易孕期或避孕。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
    floatingActionButton: FloatingActionButton(
      tooltip: '记录经期',
      onPressed: controller.mutating
          ? null
          : () => showCycleRecordEditor(context, controller: controller),
      child: const Icon(Icons.add),
    ),
  );
}

class _PredictionSummary extends StatelessWidget {
  const _PredictionSummary({required this.prediction});

  final CyclePrediction? prediction;

  @override
  Widget build(BuildContext context) {
    final value = prediction;
    if (value == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('下一次预测', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          const Text('数据不足。需要至少 2 个有效周期区间。'),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('下一次预测', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          _dateLabel(value.predictedStart),
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            color: Theme.of(context).colorScheme.tertiary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '可能开始范围：${_dateLabel(value.possibleStart)} - '
          '${_dateLabel(value.possibleEnd)}',
        ),
        Text(
          '典型周期 ${value.typicalCycleLength} 天'
          '${value.predictedDuration == null ? '' : ' · 预计持续 ${value.predictedDuration} 天'}'
          ' · ${_confidenceLabel(value.confidence)}置信度',
        ),
        Text(
          '基于最近 ${value.sampleSize} 个周期区间 · 算法 ${value.algorithmVersion}',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        if (value.suspectedMissedRecord)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '历史中存在接近两倍长度的周期，可能有漏记，请核对记录。',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }
}

String _periodLabel(CyclePeriodRecord period) {
  final end = period.endDate;
  return end == null
      ? '${_dateLabel(period.startDate)}起 · 进行中'
      : '${_dateLabel(period.startDate)} - ${_dateLabel(end)}';
}

String _periodSubtitle(CyclePeriodRecord period) {
  final parts = <String>[
    if (period.durationDays != null) '持续 ${period.durationDays} 天',
    if (period.excludedFromPrediction) '不参与预测',
    if (period.context != null) _contextSummaryLabel(period.context!),
  ];
  return parts.isEmpty ? '已记录' : parts.join(' · ');
}

String _dateLabel(DateTime date) => '${date.year}年${date.month}月${date.day}日';

String _confidenceLabel(CyclePredictionConfidence value) => switch (value) {
  CyclePredictionConfidence.insufficient => '不足',
  CyclePredictionConfidence.low => '低',
  CyclePredictionConfidence.medium => '中',
  CyclePredictionConfidence.high => '较高',
};

String _contextSummaryLabel(CycleContext value) => switch (value) {
  CycleContext.pregnancy => '怀孕',
  CycleContext.postpartum => '产后',
  CycleContext.hormonalChange => '激素变化',
  CycleContext.procedure => '医疗操作',
  CycleContext.other => '非典型周期',
};
