import 'package:flutter/material.dart';

import '../../domain/item.dart';
import '../../utils/configured_time.dart';
import '../../utils/date_formatters.dart';
import '../../utils/tag_colors.dart';
import 'calendar_navigation_controller.dart';

class CalendarMonthGrid extends StatelessWidget {
  const CalendarMonthGrid({
    super.key,
    required this.navigation,
    required this.items,
    required this.onEdit,
    required this.onDateSelected,
    this.tagColors = const {},
  });

  final CalendarNavigationController navigation;
  final List<CalendarItem> items;
  final ValueChanged<CalendarItem> onEdit;
  final ValueChanged<DateTime> onDateSelected;
  final Map<String, int> tagColors;

  @override
  Widget build(BuildContext context) {
    final start = navigation.monthGridStart;
    final end = navigation.monthGridEnd;
    final weeks = <List<DateTime>>[];
    for (
      var weekStart = start;
      weekStart.isBefore(end);
      weekStart = weekStart.add(const Duration(days: 7))
    ) {
      weeks.add(
        List<DateTime>.generate(
          7,
          (index) => weekStart.add(Duration(days: index)),
          growable: false,
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth < 760 ? 760.0 : constraints.maxWidth;
        return Scrollbar(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
            child: SizedBox(
              width: width,
              child: Column(
                children: [
                  _WeekdayHeader(firstWeek: weeks.first),
                  for (final week in weeks)
                    _MonthWeekRow(
                      week: week,
                      selectedDate: navigation.selectedDate,
                      currentMonth: navigation.selectedDate.month,
                      items: items,
                      navigation: navigation,
                      onEdit: onEdit,
                      onDateSelected: onDateSelected,
                      tagColors: tagColors,
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _WeekdayHeader extends StatelessWidget {
  const _WeekdayHeader({required this.firstWeek});

  final List<DateTime> firstWeek;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 34,
    child: Row(
      children: [
        const SizedBox(width: 44, child: Center(child: Text('周'))),
        for (final date in firstWeek)
          Expanded(
            child: Center(
              child: Text(
                formatWeekday(context, date),
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
          ),
      ],
    ),
  );
}

class _MonthWeekRow extends StatelessWidget {
  const _MonthWeekRow({
    required this.week,
    required this.selectedDate,
    required this.currentMonth,
    required this.items,
    required this.navigation,
    required this.onEdit,
    required this.onDateSelected,
    required this.tagColors,
  });

  final List<DateTime> week;
  final DateTime selectedDate;
  final int currentMonth;
  final List<CalendarItem> items;
  final CalendarNavigationController navigation;
  final ValueChanged<CalendarItem> onEdit;
  final ValueChanged<DateTime> onDateSelected;
  final Map<String, int> tagColors;

  @override
  Widget build(BuildContext context) {
    final weekNumber = isoWeekNumber(week.first);
    return SizedBox(
      height: 112,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 44,
            child: Tooltip(
              message: '查看第 $weekNumber 周',
              child: InkWell(
                onTap: () {
                  navigation.selectDate(week.first);
                  navigation.setMode(CalendarViewMode.week);
                },
                child: Center(
                  child: Text(
                    '$weekNumber',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
          for (final date in week)
            Expanded(
              child: _MonthDayCell(
                date: date,
                isCurrentMonth: date.month == currentMonth,
                isSelected: _sameDate(date, selectedDate),
                events: navigation.eventsForDate(items, date),
                onSelect: () => onDateSelected(date),
                onEdit: onEdit,
                tagColors: tagColors,
              ),
            ),
        ],
      ),
    );
  }
}

class _MonthDayCell extends StatelessWidget {
  const _MonthDayCell({
    required this.date,
    required this.isCurrentMonth,
    required this.isSelected,
    required this.events,
    required this.onSelect,
    required this.onEdit,
    required this.tagColors,
  });

  final DateTime date;
  final bool isCurrentMonth;
  final bool isSelected;
  final List<CalendarItem> events;
  final VoidCallback onSelect;
  final ValueChanged<CalendarItem> onEdit;
  final Map<String, int> tagColors;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isToday = _sameDate(date, configuredNow());
    return DecoratedBox(
      decoration: BoxDecoration(
        color: isSelected
            ? colorScheme.primaryContainer.withAlpha(90)
            : isCurrentMonth
            ? colorScheme.surface
            : colorScheme.surface.withAlpha(120),
        border: Border(
          right: BorderSide(color: colorScheme.outlineVariant, width: 0.5),
          bottom: BorderSide(color: colorScheme.outlineVariant, width: 0.5),
        ),
      ),
      child: InkWell(
        onTap: onSelect,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 5, 5, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.topRight,
                child: _DayNumber(
                  day: date.day,
                  isToday: isToday,
                  isCurrentMonth: isCurrentMonth,
                  isSelected: isSelected,
                ),
              ),
              const SizedBox(height: 3),
              for (final event in events.take(3))
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: _MonthEventChip(
                    item: event,
                    tagColors: tagColors,
                    onTap: () => onEdit(event),
                  ),
                ),
              if (events.length > 3)
                InkWell(
                  onTap: () => _showAllEvents(context),
                  child: Text(
                    '+${events.length - 3} 项',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showAllEvents(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(formatDate(context, date)),
        content: SizedBox(
          width: 440,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: events.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event_outlined),
              title: Text(events[index].title),
              onTap: () {
                Navigator.pop(context);
                onEdit(events[index]);
              },
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}

class _DayNumber extends StatelessWidget {
  const _DayNumber({
    required this.day,
    required this.isToday,
    required this.isCurrentMonth,
    required this.isSelected,
  });

  final int day;
  final bool isToday;
  final bool isCurrentMonth;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(
      color: isCurrentMonth ? colorScheme.onSurface : colorScheme.outline,
      fontWeight: FontWeight.w600,
    );
    final highlighted = isToday || isSelected;
    if (!highlighted) return Text('$day', style: style);
    return Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isToday ? colorScheme.tertiary : colorScheme.primary,
        shape: BoxShape.circle,
      ),
      child: Text(
        '$day',
        style: style?.copyWith(
          color: isToday ? colorScheme.onTertiary : colorScheme.onPrimary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _MonthEventChip extends StatelessWidget {
  const _MonthEventChip({
    required this.item,
    required this.tagColors,
    required this.onTap,
  });

  final CalendarItem item;
  final Map<String, int> tagColors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final tagged = item.tags.isNotEmpty;
    final accent = tagged
        ? colorForTag(item.tags.first, tagColors)
        : colorScheme.secondaryContainer;
    final onAccent = tagged
        ? onTagColor(accent)
        : colorScheme.onSecondaryContainer;
    return Material(
      color: accent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          child: Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: onAccent,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

bool _sameDate(DateTime left, DateTime right) =>
    left.year == right.year &&
    left.month == right.month &&
    left.day == right.day;
