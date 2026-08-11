import 'package:flutter/material.dart';

import '../../application/item_controller.dart';
import '../../domain/item.dart';
import '../../utils/date_formatters.dart';
import '../../utils/configured_time.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/item_tile.dart';

class TodayPage extends StatelessWidget {
  const TodayPage({
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
  Widget build(BuildContext context) {
    final items = controller.todayItems;
    final events = items
        .where((item) => item.type == ItemType.event)
        .toList(growable: false);
    final dues = items
        .where((item) => item.type == ItemType.task)
        .toList(growable: false);
    final notes = items
        .where((item) => item.type == ItemType.note)
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PageHeader(
          title: '今天',
          subtitle: formatToday(configuredNow()),
          count: items.length,
        ),
        Expanded(
          child: items.isEmpty
              ? const EmptyState(
                  icon: Icons.today_outlined,
                  title: '今天还没有安排',
                  message: '新建日程或 Due 后会显示在这里。',
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 96),
                  children: [
                    if (events.isNotEmpty)
                      _Section(
                        title: '日程',
                        items: events,
                        onEdit: onEdit,
                        onDelete: onDelete,
                        onToggleCompleted: onToggleCompleted,
                      ),
                    if (dues.isNotEmpty)
                      _Section(
                        title: 'Due',
                        items: dues,
                        onEdit: onEdit,
                        onDelete: onDelete,
                        onToggleCompleted: onToggleCompleted,
                      ),
                    if (notes.isNotEmpty)
                      _Section(
                        title: '笔记',
                        items: notes,
                        onEdit: onEdit,
                        onDelete: onDelete,
                        onToggleCompleted: onToggleCompleted,
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _PageHeader extends StatelessWidget {
  const _PageHeader({
    required this.title,
    required this.subtitle,
    required this.count,
  });

  final String title;
  final String subtitle;
  final int count;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Text('$count 项', style: Theme.of(context).textTheme.labelLarge),
      ],
    ),
  );
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.items,
    required this.onEdit,
    required this.onDelete,
    required this.onToggleCompleted,
  });

  final String title;
  final List<CalendarItem> items;
  final ValueChanged<CalendarItem> onEdit;
  final ValueChanged<CalendarItem> onDelete;
  final void Function(CalendarItem item, bool completed) onToggleCompleted;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(title, style: Theme.of(context).textTheme.titleSmall),
        ),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Column(
            children: [
              for (final item in items)
                ItemTile(
                  item: item,
                  onEdit: () => onEdit(item),
                  onDelete: () => onDelete(item),
                  onToggleCompleted: item.type == ItemType.task
                      ? (value) => onToggleCompleted(item, value)
                      : null,
                ),
            ],
          ),
        ),
      ],
    ),
  );
}
