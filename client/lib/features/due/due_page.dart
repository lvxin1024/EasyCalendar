import 'package:flutter/material.dart';

import '../../domain/item.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/item_tile.dart';
import '../../widgets/tag_filter_bar.dart';
import '../../utils/configured_time.dart';

enum DueFilter { open, overdue, completed }

class DueItemsSection extends StatefulWidget {
  const DueItemsSection({
    super.key,
    required this.items,
    required this.tagColors,
    required this.onEdit,
    required this.onDelete,
    required this.onToggleCompleted,
  });

  final List<CalendarItem> items;
  final Map<String, int> tagColors;
  final ValueChanged<CalendarItem> onEdit;
  final ValueChanged<CalendarItem> onDelete;
  final void Function(CalendarItem item, bool completed) onToggleCompleted;

  @override
  State<DueItemsSection> createState() => _DueItemsSectionState();
}

class _DueItemsSectionState extends State<DueItemsSection> {
  DueFilter _filter = DueFilter.open;
  Set<String> _selectedTags = const {};

  @override
  Widget build(BuildContext context) {
    final now = configuredNow();
    final items = widget.items
        .where((item) {
          return dueMatchesFilter(item, _filter, now) &&
              matchesTagFilter(item, _selectedTags);
        })
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(20, 2, 20, 12),
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
            onSelectionChanged: (value) =>
                setState(() => _filter = value.first),
          ),
        ),
        TagFilterBar(
          tags: tagsFromItems(widget.items),
          selectedTags: _selectedTags,
          colors: widget.tagColors,
          onChanged: (value) => setState(() => _selectedTags = value),
        ),
        Expanded(
          child: items.isEmpty
              ? EmptyState(
                  icon: _filter == DueFilter.completed
                      ? Icons.task_alt
                      : Icons.check_circle_outline,
                  title: _filter == DueFilter.completed
                      ? '还没有已完成 Due'
                      : '当前没有 Due',
                  message: '创建带截止时间的 Due 后会显示在这里。',
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 96),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return ItemTile(
                      item: item,
                      highlightOverdue:
                          item.status != ItemStatus.done &&
                          item.dueAt!.isBefore(now),
                      onEdit: () => widget.onEdit(item),
                      onDelete: () => widget.onDelete(item),
                      onToggleCompleted: (value) =>
                          widget.onToggleCompleted(item, value),
                      tagColors: widget.tagColors,
                    );
                  },
                ),
        ),
      ],
    );
  }
}

@visibleForTesting
bool dueMatchesFilter(CalendarItem item, DueFilter filter, DateTime now) {
  final completed = item.status == ItemStatus.done;
  final overdue = !completed && item.dueAt!.isBefore(now);
  return switch (filter) {
    DueFilter.open => !completed,
    DueFilter.overdue => overdue,
    DueFilter.completed => completed,
  };
}
