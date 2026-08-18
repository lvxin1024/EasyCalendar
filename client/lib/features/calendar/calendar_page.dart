import 'package:flutter/material.dart';

import '../../application/item_controller.dart';
import '../../domain/item.dart';
import '../../utils/configured_time.dart';
import '../../utils/date_formatters.dart';
import 'calendar_navigation_controller.dart';
import 'calendar_month_grid.dart';
import 'calendar_time_grid.dart';
import '../../widgets/tag_filter_bar.dart';

class CalendarPage extends StatefulWidget {
  const CalendarPage({
    super.key,
    required this.controller,
    required this.navigation,
    required this.onEdit,
    required this.onDelete,
  });

  final ItemController controller;
  final CalendarNavigationController navigation;
  final ValueChanged<CalendarItem> onEdit;
  final ValueChanged<CalendarItem> onDelete;

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  double _hourHeight = 72;
  Set<String> _selectedTags = const {};

  @override
  Widget build(BuildContext context) {
    final configured = widget.controller.preferences.firstDayOfWeek;
    final materialIndex = MaterialLocalizations.of(context).firstDayOfWeekIndex;
    widget.navigation.updateFirstDayOfWeek(
      configured == 0 ? materialWeekdayToDateTime(materialIndex) : configured,
      notify: false,
    );
    return AnimatedBuilder(
      animation: widget.navigation,
      builder: (context, _) {
        final filteredItems = widget.controller.items
            .where((item) => matchesTagFilter(item, _selectedTags))
            .toList(growable: false);
        final events = widget.navigation.eventsInRange(filteredItems);
        final dues =
            filteredItems
                .where(
                  (item) =>
                      item.type == ItemType.task &&
                      item.status == ItemStatus.todo,
                )
                .toList(growable: false)
              ..sort((left, right) => left.dueAt!.compareTo(right.dueAt!));
        final availableTags = tagsFromItems(widget.controller.items);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _CalendarToolbar(navigation: widget.navigation),
            const Divider(),
            TagFilterBar(
              tags: availableTags,
              selectedTags: _selectedTags,
              colors: widget.controller.preferences.tagColors,
              onChanged: (value) => setState(() => _selectedTags = value),
            ),
            if (dues.isNotEmpty)
              _PinnedDueStrip(items: dues, onEdit: widget.onEdit),
            Expanded(
              child: widget.navigation.mode == CalendarViewMode.month
                  ? CalendarMonthGrid(
                      navigation: widget.navigation,
                      items: widget.navigation.calendarItemsInRange(
                        widget.controller.items,
                      ),
                      onEdit: widget.onEdit,
                      tagColors: widget.controller.preferences.tagColors,
                    )
                  : CalendarTimeGrid(
                      dates: widget.navigation.visibleDates,
                      items: events,
                      dueItems: dues,
                      tagColors: widget.controller.preferences.tagColors,
                      selectedDate: widget.navigation.selectedDate,
                      hourHeight: _hourHeight,
                      onHourHeightChanged: (value) =>
                          setState(() => _hourHeight = value.clamp(16, 120)),
                      onDateSelected: widget.navigation.selectDate,
                      onEdit: widget.onEdit,
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _PinnedDueStrip extends StatelessWidget {
  const _PinnedDueStrip({required this.items, required this.onEdit});

  final List<CalendarItem> items;
  final ValueChanged<CalendarItem> onEdit;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(maxHeight: 82),
    padding: const EdgeInsets.fromLTRB(20, 6, 20, 8),
    color: Theme.of(context).colorScheme.errorContainer.withAlpha(90),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 5, right: 12),
          child: Text(
            '未完成 Due',
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final item in items)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ActionChip(
                      avatar: const Icon(Icons.check_circle_outline, size: 16),
                      label: Text(
                        '${item.title} · ${_dueLabel(context, item.dueAt!)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onPressed: () => onEdit(item),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  static String _dueLabel(BuildContext context, DateTime value) {
    final local = inConfiguredTimezone(value);
    return '${formatMonthDay(context, local)} ${formatTime(context, local)}';
  }
}

class _CalendarToolbar extends StatelessWidget {
  const _CalendarToolbar({required this.navigation});

  final CalendarNavigationController navigation;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
    child: Wrap(
      spacing: 16,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      alignment: WrapAlignment.spaceBetween,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '上一${_periodLabel(navigation.mode)}',
              onPressed: navigation.previous,
              icon: const Icon(Icons.chevron_left),
            ),
            OutlinedButton(
              onPressed: navigation.goToToday,
              child: const Text('今天'),
            ),
            IconButton(
              tooltip: '下一${_periodLabel(navigation.mode)}',
              onPressed: navigation.next,
              icon: const Icon(Icons.chevron_right),
            ),
            const SizedBox(width: 8),
            Text(
              _rangeTitle(context, navigation),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
        SegmentedButton<CalendarViewMode>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
              value: CalendarViewMode.day,
              icon: Icon(Icons.view_day_outlined),
              label: Text('日'),
            ),
            ButtonSegment(
              value: CalendarViewMode.week,
              icon: Icon(Icons.view_week_outlined),
              label: Text('周'),
            ),
            ButtonSegment(
              value: CalendarViewMode.month,
              icon: Icon(Icons.calendar_view_month_outlined),
              label: Text('月'),
            ),
          ],
          selected: {navigation.mode},
          onSelectionChanged: (value) => navigation.setMode(value.first),
        ),
      ],
    ),
  );
}

String _rangeTitle(
  BuildContext context,
  CalendarNavigationController navigation,
) => switch (navigation.mode) {
  CalendarViewMode.day => formatDateWithWeekday(
    context,
    navigation.selectedDate,
  ),
  CalendarViewMode.week =>
    '${formatMonthDay(context, navigation.rangeStart)}'
        ' - '
        '${formatMonthDay(context, navigation.rangeEnd.subtract(const Duration(days: 1)))}',
  CalendarViewMode.month => formatMonth(context, navigation.selectedDate),
};

String _periodLabel(CalendarViewMode mode) => switch (mode) {
  CalendarViewMode.day => '天',
  CalendarViewMode.week => '周',
  CalendarViewMode.month => '月',
};
