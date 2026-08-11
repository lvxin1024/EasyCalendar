import 'package:flutter/material.dart';

import '../../application/item_controller.dart';
import '../../domain/item.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/item_tile.dart';
import '../../utils/configured_time.dart';

enum DueFilter { open, overdue, completed }

class DuePage extends StatefulWidget {
  const DuePage({
    super.key,
    required this.controller,
    required this.onEdit,
    required this.onDelete,
    required this.onToggleCompleted,
  });

  final ItemController controller;
  final ValueChanged<CalendarItem> onEdit;
  final ValueChanged<CalendarItem> onDelete;
  final void Function(CalendarItem item, bool completed) onToggleCompleted;

  @override
  State<DuePage> createState() => _DuePageState();
}

class _DuePageState extends State<DuePage> {
  DueFilter _filter = DueFilter.open;

  @override
  Widget build(BuildContext context) {
    final now = configuredNow();
    final items = widget.controller.dueItems.where((item) {
      final completed = item.status == ItemStatus.done;
      final overdue = !completed && item.dueAt!.isBefore(now);
      return switch (_filter) {
        DueFilter.open => !completed,
        DueFilter.overdue => overdue,
        DueFilter.completed => completed,
      };
    }).toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 14),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Due',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              Text(
                '${items.length} 项',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ],
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: SegmentedButton<DueFilter>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: DueFilter.open, label: Text('待完成')),
              ButtonSegment(
                value: DueFilter.overdue,
                icon: Icon(Icons.error_outline),
                label: Text('已逾期'),
              ),
              ButtonSegment(
                value: DueFilter.completed,
                icon: Icon(Icons.task_alt),
                label: Text('已完成'),
              ),
            ],
            selected: {_filter},
            onSelectionChanged: (value) => setState(() => _filter = value.first),
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? EmptyState(
                  icon: _filter == DueFilter.completed
                      ? Icons.task_alt
                      : Icons.check_circle_outline,
                  title: _filter == DueFilter.completed ? '还没有已完成 Due' : '当前没有 Due',
                  message: '创建带截止时间的 Due 后会显示在这里。',
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 96),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return ItemTile(
                      item: item,
                      highlightOverdue: item.status != ItemStatus.done &&
                          item.dueAt!.isBefore(now),
                      onEdit: () => widget.onEdit(item),
                      onDelete: () => widget.onDelete(item),
                      onToggleCompleted: (value) =>
                          widget.onToggleCompleted(item, value),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
