import 'package:flutter/material.dart';

import '../../application/item_controller.dart';
import '../../domain/item.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/item_tile.dart';
import '../../widgets/tag_filter_bar.dart';
import '../../utils/configured_time.dart';

enum ItemTypeFilter { all, event, task, note }

class ItemsPage extends StatefulWidget {
  const ItemsPage({
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
  State<ItemsPage> createState() => _ItemsPageState();
}

class _ItemsPageState extends State<ItemsPage> {
  final _searchController = TextEditingController();
  ItemTypeFilter _filter = ItemTypeFilter.all;
  Set<String> _selectedTags = const {};

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = configuredNow();
    final query = _searchController.text.trim().toLowerCase();
    final currentItems = widget.controller.items
        .where((item) => isVisibleInAllItems(item, now))
        .toList(growable: false);
    final items = currentItems
        .where((item) {
          final matchesType =
              _filter == ItemTypeFilter.all || item.type.name == _filter.name;
          final matchesQuery =
              query.isEmpty ||
              item.title.toLowerCase().contains(query) ||
              (item.body?.toLowerCase().contains(query) ?? false) ||
              item.tags.any((tag) => tag.toLowerCase().contains(query));
          return matchesType &&
              matchesQuery &&
              matchesTagFilter(item, _selectedTags);
        })
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
          child: Text('全部事项', style: Theme.of(context).textTheme.headlineSmall),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: SearchBar(
            controller: _searchController,
            hintText: '搜索标题、正文或标签',
            leading: const Icon(Icons.search),
            trailing: [
              if (_searchController.text.isNotEmpty)
                IconButton(
                  tooltip: '清空搜索',
                  onPressed: () => setState(_searchController.clear),
                  icon: const Icon(Icons.close),
                ),
            ],
            onChanged: (_) => setState(() {}),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
          child: SegmentedButton<ItemTypeFilter>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: ItemTypeFilter.all, label: Text('全部')),
              ButtonSegment(
                value: ItemTypeFilter.event,
                icon: Icon(Icons.event_outlined),
                label: Text('日程'),
              ),
              ButtonSegment(
                value: ItemTypeFilter.task,
                icon: Icon(Icons.check_circle_outline),
                label: Text('Due'),
              ),
              ButtonSegment(
                value: ItemTypeFilter.note,
                icon: Icon(Icons.notes_outlined),
                label: Text('笔记'),
              ),
            ],
            selected: {_filter},
            onSelectionChanged: (value) =>
                setState(() => _filter = value.first),
          ),
        ),
        TagFilterBar(
          tags: tagsFromItems(currentItems),
          selectedTags: _selectedTags,
          colors: widget.controller.preferences.tagColors,
          onChanged: (value) => setState(() => _selectedTags = value),
        ),
        Expanded(
          child: items.isEmpty
              ? const EmptyState(
                  icon: Icons.inbox_outlined,
                  title: '没有匹配的事项',
                  message: '调整搜索或筛选条件。',
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 96),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return ItemTile(
                      item: item,
                      onEdit: () => widget.onEdit(item),
                      onDelete: () => widget.onDelete(item),
                      onToggleCompleted: item.type == ItemType.task
                          ? (value) => widget.onToggleCompleted(item, value)
                          : null,
                      tagColors: widget.controller.preferences.tagColors,
                    );
                  },
                ),
        ),
      ],
    );
  }
}

@visibleForTesting
bool isVisibleInAllItems(CalendarItem item, DateTime now) {
  if (item.type != ItemType.event || item.recurrence != null) return true;
  final startAt = item.startAt;
  if (startAt == null) return true;

  final localStart = inConfiguredTimezone(startAt);
  final rawEnd = item.endAt;
  final effectiveEnd = rawEnd != null && rawEnd.isAfter(startAt)
      ? inConfiguredTimezone(rawEnd)
      : item.allDay
      ? configuredDateTime(
          year: localStart.year,
          month: localStart.month,
          day: localStart.day + 1,
        )
      : localStart;
  return effectiveEnd.isAfter(inConfiguredTimezone(now));
}
