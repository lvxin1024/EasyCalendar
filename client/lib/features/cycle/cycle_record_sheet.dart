import 'package:flutter/material.dart';

import '../../application/cycle_controller.dart';
import '../../domain/cycle_record.dart';

Future<void> showCycleRecordEditor(
  BuildContext context, {
  required CycleController controller,
  CyclePeriodRecord? current,
  DateTime? initialDate,
}) async {
  final editor = _CycleRecordEditor(
    controller: controller,
    current: current,
    initialDate: initialDate,
  );
  if (MediaQuery.sizeOf(context).width >= 700) {
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 720),
          child: editor,
        ),
      ),
    );
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) =>
        FractionallySizedBox(heightFactor: 0.92, child: editor),
  );
}

class _CycleRecordEditor extends StatefulWidget {
  const _CycleRecordEditor({
    required this.controller,
    required this.current,
    required this.initialDate,
  });

  final CycleController controller;
  final CyclePeriodRecord? current;
  final DateTime? initialDate;

  @override
  State<_CycleRecordEditor> createState() => _CycleRecordEditorState();
}

class _CycleRecordEditorState extends State<_CycleRecordEditor> {
  late DateTime _startDate;
  DateTime? _endDate;
  late bool _ongoing;
  late bool _excluded;
  CycleContext? _context;
  late DateTime _logDate;
  final Map<String, CycleDailyLogDraft> _logs = {};
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final current = widget.current;
    _startDate = cycleDate(
      current?.startDate ?? widget.initialDate ?? DateTime.now(),
    );
    _endDate = current?.endDate == null ? null : cycleDate(current!.endDate!);
    _ongoing = current != null && current.endDate == null;
    _excluded = current?.excludedFromPrediction ?? false;
    _context = current?.context;
    _logDate = _startDate;
    if (current != null) {
      for (final log in widget.controller.dailyLogsForPeriod(current.id)) {
        _logs[cycleDateKey(log.date)] = CycleDailyLogDraft(
          date: log.date,
          bleedingLevel: log.bleedingLevel,
          spotting: log.spotting,
          symptoms: log.symptoms,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 12, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.current == null ? '记录经期' : '编辑经期记录',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: '关闭',
                onPressed: _saving ? null : () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            children: [
              _DateField(
                label: '开始日期',
                value: _startDate,
                onTap: () => _pickDate(start: true),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('仍在进行中'),
                value: _ongoing,
                onChanged: (value) => setState(() {
                  _ongoing = value;
                  if (value) _endDate = null;
                }),
              ),
              if (!_ongoing)
                _DateField(
                  label: '结束日期',
                  value: _endDate,
                  placeholder: '选择结束日期',
                  onTap: () => _pickDate(start: false),
                ),
              const SizedBox(height: 12),
              DropdownButtonFormField<CycleContext?>(
                initialValue: _context,
                decoration: const InputDecoration(
                  labelText: '本周期背景（可选）',
                  prefixIcon: Icon(Icons.info_outline),
                ),
                items: [
                  const DropdownMenuItem(value: null, child: Text('无')),
                  for (final value in CycleContext.values)
                    DropdownMenuItem(
                      value: value,
                      child: Text(_contextLabel(value)),
                    ),
                ],
                onChanged: (value) => setState(() => _context = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('不参与预测'),
                subtitle: const Text('记录仍会保留并显示在日历中'),
                value: _excluded,
                onChanged: (value) => setState(() => _excluded = value),
              ),
              const Divider(height: 28),
              Text('每日记录（可选）', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              DropdownButtonFormField<DateTime>(
                key: ValueKey(cycleDateKey(_logDate)),
                initialValue: _availableLogDates.contains(_logDate)
                    ? _logDate
                    : _availableLogDates.first,
                decoration: const InputDecoration(
                  labelText: '记录日期',
                  prefixIcon: Icon(Icons.today_outlined),
                ),
                items: [
                  for (final date in _availableLogDates)
                    DropdownMenuItem(
                      value: date,
                      child: Text(_dateLabel(date)),
                    ),
                ],
                onChanged: (date) {
                  if (date != null) setState(() => _logDate = date);
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<CycleFlowLevel?>(
                key: ValueKey(
                  '${cycleDateKey(_logDate)}-${_currentLog.bleedingLevel?.name}',
                ),
                initialValue: _currentLog.bleedingLevel,
                decoration: const InputDecoration(
                  labelText: '流量',
                  prefixIcon: Icon(Icons.opacity_outlined),
                ),
                items: const [
                  DropdownMenuItem(value: null, child: Text('未记录')),
                  DropdownMenuItem(
                    value: CycleFlowLevel.light,
                    child: Text('少量'),
                  ),
                  DropdownMenuItem(
                    value: CycleFlowLevel.medium,
                    child: Text('中等'),
                  ),
                  DropdownMenuItem(
                    value: CycleFlowLevel.heavy,
                    child: Text('大量'),
                  ),
                ],
                onChanged: _setCurrentFlow,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('点滴出血'),
                value: _currentLog.spotting,
                onChanged: _setCurrentSpotting,
              ),
              Text('症状', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 6),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  for (final symptom in CycleSymptom.values)
                    FilterChip(
                      label: Text(_symptomLabel(symptom)),
                      selected: _currentLog.symptoms.contains(symptom),
                      onSelected: (selected) =>
                          _toggleSymptom(symptom, selected),
                    ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              if (widget.current != null)
                TextButton.icon(
                  onPressed: _saving ? null : _confirmDelete,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('删除'),
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                ),
              const Spacer(),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: const Text('保存'),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  List<DateTime> get _availableLogDates {
    final end = cycleDate(_endDate ?? DateTime.now());
    final safeEnd = end.isBefore(_startDate) ? _startDate : end;
    final count = safeEnd.difference(_startDate).inDays.clamp(0, 119) + 1;
    return List.generate(
      count,
      (index) => _startDate.add(Duration(days: index)),
      growable: false,
    );
  }

  CycleDailyLogDraft get _currentLog =>
      _logs[cycleDateKey(_logDate)] ?? CycleDailyLogDraft(date: _logDate);

  Future<void> _pickDate({required bool start}) async {
    final selected = await showDatePicker(
      context: context,
      initialDate: start ? _startDate : (_endDate ?? _startDate),
      firstDate: DateTime(1900),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (selected == null) return;
    setState(() {
      if (start) {
        _startDate = cycleDate(selected);
        if (_endDate != null && _endDate!.isBefore(_startDate)) {
          _endDate = _startDate;
        }
        if (_logDate.isBefore(_startDate)) _logDate = _startDate;
      } else {
        _endDate = cycleDate(selected);
      }
    });
  }

  void _setCurrentFlow(CycleFlowLevel? bleedingLevel) {
    final current = _currentLog;
    setState(() {
      _logs[cycleDateKey(_logDate)] = CycleDailyLogDraft(
        date: _logDate,
        bleedingLevel: bleedingLevel,
        spotting: current.spotting,
        symptoms: current.symptoms,
      );
    });
  }

  void _setCurrentSpotting(bool spotting) {
    final current = _currentLog;
    setState(() {
      _logs[cycleDateKey(_logDate)] = CycleDailyLogDraft(
        date: _logDate,
        bleedingLevel: current.bleedingLevel,
        spotting: spotting,
        symptoms: current.symptoms,
      );
    });
  }

  void _toggleSymptom(CycleSymptom symptom, bool selected) {
    final current = _currentLog;
    final symptoms = {...current.symptoms};
    selected ? symptoms.add(symptom) : symptoms.remove(symptom);
    setState(() {
      _logs[cycleDateKey(_logDate)] = CycleDailyLogDraft(
        date: _logDate,
        bleedingLevel: current.bleedingLevel,
        spotting: current.spotting,
        symptoms: symptoms,
      );
    });
  }

  Future<void> _save() async {
    if (!_ongoing && _endDate == null) {
      setState(() => _error = '请选择结束日期，或标记为仍在进行中');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final draft = CyclePeriodDraft(
      startDate: _startDate,
      endDate: _ongoing ? null : _endDate,
      excludedFromPrediction: _excluded,
      context: _context,
    );
    try {
      final logs = _logs.values.where((log) => !log.isEmpty).toList();
      if (widget.current == null) {
        await widget.controller.createPeriod(draft, dailyLogs: logs);
      } else {
        await widget.controller.updatePeriod(
          widget.current!,
          draft,
          dailyLogs: logs,
        );
      }
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除经期记录？'),
        content: const Text('这会同时删除该周期的每日流量和症状记录，且无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _saving = true);
    try {
      await widget.controller.deletePeriod(widget.current!.id);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.onTap,
    this.placeholder,
  });

  final String label;
  final DateTime? value;
  final VoidCallback onTap;
  final String? placeholder;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
      side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    leading: const Icon(Icons.calendar_today_outlined),
    title: Text(label),
    subtitle: Text(value == null ? placeholder ?? '未选择' : _dateLabel(value!)),
    trailing: const Icon(Icons.edit_calendar_outlined),
    onTap: onTap,
  );
}

String _dateLabel(DateTime date) => '${date.year}年${date.month}月${date.day}日';

String _contextLabel(CycleContext value) => switch (value) {
  CycleContext.pregnancy => '怀孕',
  CycleContext.postpartum => '产后',
  CycleContext.hormonalChange => '激素避孕变化',
  CycleContext.procedure => '医疗操作',
  CycleContext.other => '其他非典型情况',
};

String _symptomLabel(CycleSymptom value) => switch (value) {
  CycleSymptom.cramps => '腹痛',
  CycleSymptom.headache => '头痛',
  CycleSymptom.mood => '情绪变化',
  CycleSymptom.fatigue => '疲劳',
};
