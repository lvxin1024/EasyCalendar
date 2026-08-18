import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/item.dart';
import '../../utils/configured_time.dart';
import '../../utils/date_formatters.dart';
import '../../utils/tag_colors.dart';
import 'calendar_navigation_controller.dart';

class CalendarEventPlacement {
  const CalendarEventPlacement({
    required this.item,
    required this.startMinutes,
    required this.endMinutes,
    required this.column,
    required this.columnCount,
  });

  final CalendarItem item;
  final int startMinutes;
  final int endMinutes;
  final int column;
  final int columnCount;
}

List<CalendarEventPlacement> layoutTimedEvents(
  List<CalendarItem> items,
  DateTime date, {
  List<CalendarItem> dueItems = const [],
}) {
  final dayStart = configuredDateTime(
    year: date.year,
    month: date.month,
    day: date.day,
  );
  final dayEnd = configuredDateTime(
    year: date.year,
    month: date.month,
    day: date.day + 1,
  );
  final segments = <_EventSegment>[];
  for (final item in items) {
    if (item.allDay || item.startAt == null) continue;
    final start = inConfiguredTimezone(item.startAt!);
    var end = item.endAt == null
        ? start.add(const Duration(minutes: 30))
        : inConfiguredTimezone(item.endAt!);
    if (!end.isAfter(start)) end = start.add(const Duration(minutes: 30));
    if (!start.isBefore(dayEnd) || !end.isAfter(dayStart)) continue;
    final clippedStart = start.isBefore(dayStart) ? dayStart : start;
    final clippedEnd = end.isAfter(dayEnd) ? dayEnd : end;
    segments.add(
      _EventSegment(
        item: item,
        startMinutes: clippedStart
            .difference(dayStart)
            .inMinutes
            .clamp(0, 1440),
        endMinutes: clippedEnd.difference(dayStart).inMinutes.clamp(0, 1440),
      ),
    );
  }
  for (final item in dueItems) {
    if (item.status != ItemStatus.todo || item.dueAt == null) continue;
    final end = inConfiguredTimezone(item.dueAt!);
    final start = end.subtract(const Duration(minutes: 30));
    if (!start.isBefore(dayEnd) || !end.isAfter(dayStart)) continue;
    final clippedStart = start.isBefore(dayStart) ? dayStart : start;
    final clippedEnd = end.isAfter(dayEnd) ? dayEnd : end;
    if (!clippedEnd.isAfter(clippedStart)) continue;
    segments.add(
      _EventSegment(
        item: item,
        startMinutes: clippedStart
            .difference(dayStart)
            .inMinutes
            .clamp(0, 1440),
        endMinutes: clippedEnd.difference(dayStart).inMinutes.clamp(0, 1440),
      ),
    );
  }
  segments.sort((left, right) {
    final start = left.startMinutes.compareTo(right.startMinutes);
    if (start != 0) return start;
    final end = left.endMinutes.compareTo(right.endMinutes);
    return end != 0 ? end : left.item.id.compareTo(right.item.id);
  });

  final placements = <CalendarEventPlacement>[];
  var groupStart = 0;
  while (groupStart < segments.length) {
    var groupEnd = groupStart + 1;
    var latestEnd = segments[groupStart].endMinutes;
    while (groupEnd < segments.length &&
        segments[groupEnd].startMinutes < latestEnd) {
      latestEnd = math.max(latestEnd, segments[groupEnd].endMinutes);
      groupEnd += 1;
    }
    final columns = <int>[];
    final assigned = <({int column, _EventSegment segment})>[];
    for (final segment in segments.sublist(groupStart, groupEnd)) {
      var column = columns.indexWhere((end) => end <= segment.startMinutes);
      if (column == -1) {
        column = columns.length;
        columns.add(segment.endMinutes);
      } else {
        columns[column] = segment.endMinutes;
      }
      assigned.add((column: column, segment: segment));
    }
    for (final value in assigned) {
      placements.add(
        CalendarEventPlacement(
          item: value.segment.item,
          startMinutes: value.segment.startMinutes,
          endMinutes: value.segment.endMinutes,
          column: value.column,
          columnCount: columns.length,
        ),
      );
    }
    groupStart = groupEnd;
  }
  return placements;
}

class CalendarTimeGrid extends StatefulWidget {
  const CalendarTimeGrid({
    super.key,
    required this.dates,
    required this.items,
    required this.dueItems,
    this.tagColors = const {},
    required this.selectedDate,
    required this.hourHeight,
    required this.onHourHeightChanged,
    required this.onDateSelected,
    required this.onEdit,
  });

  final List<DateTime> dates;
  final List<CalendarItem> items;
  final List<CalendarItem> dueItems;
  final Map<String, int> tagColors;
  final DateTime selectedDate;
  final double hourHeight;
  final ValueChanged<double> onHourHeightChanged;
  final ValueChanged<DateTime> onDateSelected;
  final ValueChanged<CalendarItem> onEdit;

  @override
  State<CalendarTimeGrid> createState() => _CalendarTimeGridState();
}

class _CalendarTimeGridState extends State<CalendarTimeGrid> {
  final _verticalController = ScrollController();
  final _horizontalController = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollToWorkingHours(),
    );
  }

  @override
  void dispose() {
    _verticalController.dispose();
    _horizontalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _ZoomControl(
        value: widget.hourHeight,
        onChanged: widget.onHourHeightChanged,
      ),
      Expanded(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final minimumWidth = widget.dates.length == 1 ? 420.0 : 900.0;
            final width = math.max(constraints.maxWidth, minimumWidth);
            return Scrollbar(
              controller: _horizontalController,
              notificationPredicate: (notification) =>
                  notification.metrics.axis == Axis.horizontal,
              child: SingleChildScrollView(
                controller: _horizontalController,
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: width,
                  height: constraints.maxHeight,
                  child: Column(
                    children: [
                      _DateHeader(
                        dates: widget.dates,
                        selectedDate: widget.selectedDate,
                        onDateSelected: widget.onDateSelected,
                      ),
                      _AllDayRow(
                        dates: widget.dates,
                        items: widget.items,
                        onEdit: widget.onEdit,
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: Listener(
                          onPointerSignal: _handlePointerSignal,
                          child: Scrollbar(
                            controller: _verticalController,
                            thumbVisibility: true,
                            child: SingleChildScrollView(
                              controller: _verticalController,
                              child: SizedBox(
                                height: widget.hourHeight * 24,
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    _TimeGutter(hourHeight: widget.hourHeight),
                                    for (final date in widget.dates)
                                      Expanded(
                                        child: _DayColumn(
                                          date: date,
                                          items: widget.items,
                                          dueItems: widget.dueItems,
                                          tagColors: widget.tagColors,
                                          hourHeight: widget.hourHeight,
                                          onEdit: widget.onEdit,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ],
  );

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final keyboard = HardwareKeyboard.instance;
    if (!keyboard.isMetaPressed && !keyboard.isControlPressed) return;
    widget.onHourHeightChanged(
      (widget.hourHeight - event.scrollDelta.dy * 0.12).clamp(16, 120),
    );
  }

  void _scrollToWorkingHours() {
    if (!_verticalController.hasClients) return;
    final now = configuredNow();
    final containsToday = widget.dates.any((date) => _isSameDate(date, now));
    final targetHour = containsToday ? math.max(0, now.hour - 2) : 8;
    final offset = math.min(
      targetHour * widget.hourHeight,
      _verticalController.position.maxScrollExtent,
    );
    _verticalController.jumpTo(offset);
  }
}

class _EventSegment {
  const _EventSegment({
    required this.item,
    required this.startMinutes,
    required this.endMinutes,
  });

  final CalendarItem item;
  final int startMinutes;
  final int endMinutes;
}

class _ZoomControl extends StatelessWidget {
  const _ZoomControl({required this.value, required this.onChanged});

  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 42,
    child: Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text('时间轴', style: Theme.of(context).textTheme.labelMedium),
        IconButton(
          tooltip: '缩小时间轴',
          onPressed: value <= 16 ? null : () => onChanged(value - 8),
          icon: const Icon(Icons.zoom_out, size: 19),
        ),
        SizedBox(
          width: 120,
          child: Slider(
            value: value,
            min: 16,
            max: 120,
            divisions: 13,
            onChanged: onChanged,
          ),
        ),
        IconButton(
          tooltip: '放大时间轴',
          onPressed: value >= 120 ? null : () => onChanged(value + 8),
          icon: const Icon(Icons.zoom_in, size: 19),
        ),
        const SizedBox(width: 12),
      ],
    ),
  );
}

class _DateHeader extends StatelessWidget {
  const _DateHeader({
    required this.dates,
    required this.selectedDate,
    required this.onDateSelected,
  });

  final List<DateTime> dates;
  final DateTime selectedDate;
  final ValueChanged<DateTime> onDateSelected;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48,
    child: Row(
      children: [
        const SizedBox(width: 58),
        for (final date in dates)
          Expanded(
            child: InkWell(
              onTap: () => onDateSelected(date),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: _isSameDate(date, selectedDate)
                      ? Theme.of(context).colorScheme.primaryContainer
                      : null,
                  border: const Border(
                    left: BorderSide(color: Color(0xFFE4E7EC)),
                  ),
                ),
                child: Center(
                  child: Text(
                    formatCompactDateWithWeekday(context, date),
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _AllDayRow extends StatelessWidget {
  const _AllDayRow({
    required this.dates,
    required this.items,
    required this.onEdit,
  });

  final List<DateTime> dates;
  final List<CalendarItem> items;
  final ValueChanged<CalendarItem> onEdit;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 34, maxHeight: 76),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(
          width: 58,
          child: Center(child: Text('全天', style: TextStyle(fontSize: 11))),
        ),
        for (final date in dates)
          Expanded(
            child: DecoratedBox(
              decoration: const BoxDecoration(
                border: Border(left: BorderSide(color: Color(0xFFE4E7EC))),
              ),
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final item in _allDayItems(items, date).take(2))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: _AllDayEvent(
                          item: item,
                          onTap: () => onEdit(item),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _AllDayEvent extends StatelessWidget {
  const _AllDayEvent({required this.item, required this.onTap});

  final CalendarItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.secondaryContainer,
    borderRadius: BorderRadius.circular(4),
    child: InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        child: Text(
          item.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ),
    ),
  );
}

class _TimeGutter extends StatelessWidget {
  const _TimeGutter({required this.hourHeight});

  final double hourHeight;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 58,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        for (var hour = 0; hour < 24; hour += 1)
          Positioned(
            top: hour * hourHeight - 7,
            right: 8,
            child: Text(
              formatHourLabel(context, hour),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    ),
  );
}

class _DayColumn extends StatelessWidget {
  const _DayColumn({
    required this.date,
    required this.items,
    required this.dueItems,
    required this.tagColors,
    required this.hourHeight,
    required this.onEdit,
  });

  final DateTime date;
  final List<CalendarItem> items;
  final List<CalendarItem> dueItems;
  final Map<String, int> tagColors;
  final double hourHeight;
  final ValueChanged<CalendarItem> onEdit;

  @override
  Widget build(BuildContext context) {
    final placements = layoutTimedEvents(items, date, dueItems: dueItems);
    return LayoutBuilder(
      builder: (context, constraints) => DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(left: BorderSide(color: Color(0xFFE4E7EC))),
        ),
        child: Stack(
          children: [
            for (var hour = 0; hour < 24; hour += 1)
              Positioned(
                top: hour * hourHeight,
                left: 0,
                right: 0,
                child: const Divider(height: 1, color: Color(0xFFE4E7EC)),
              ),
            if (_isSameDate(date, configuredNow()))
              _CurrentTimeLine(hourHeight: hourHeight),
            for (final placement in placements)
              _PositionedEvent(
                placement: placement,
                availableWidth: constraints.maxWidth,
                hourHeight: hourHeight,
                tagColors: tagColors,
                onTap: () => onEdit(placement.item),
              ),
          ],
        ),
      ),
    );
  }
}

class _PositionedEvent extends StatelessWidget {
  const _PositionedEvent({
    required this.placement,
    required this.availableWidth,
    required this.hourHeight,
    required this.tagColors,
    required this.onTap,
  });

  final CalendarEventPlacement placement;
  final double availableWidth;
  final double hourHeight;
  final Map<String, int> tagColors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const gap = 2.0;
    final columnWidth = availableWidth / placement.columnCount;
    final top = placement.startMinutes / 60 * hourHeight;
    final rawHeight =
        (placement.endMinutes - placement.startMinutes) / 60 * hourHeight;
    return Positioned(
      top: top + 1,
      left: placement.column * columnWidth + gap,
      width: math.max(8, columnWidth - gap * 2),
      height: math.max(24, rawHeight - 2),
      child: Material(
        color: placement.item.type == ItemType.task
            ? Theme.of(context).colorScheme.errorContainer
            : placement.item.tags.isEmpty
            ? Theme.of(context).colorScheme.primaryContainer
            : colorForTag(placement.item.tags.first, tagColors).withAlpha(50),
        borderRadius: BorderRadius.circular(4),
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  placement.item.type == ItemType.task
                      ? 'Due · ${placement.item.title}'
                      : placement.item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (rawHeight >= 38)
                  Text(
                    _eventTime(context, placement.item),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CurrentTimeLine extends StatelessWidget {
  const _CurrentTimeLine({required this.hourHeight});

  final double hourHeight;

  @override
  Widget build(BuildContext context) {
    final now = configuredNow();
    final top = (now.hour * 60 + now.minute) / 60 * hourHeight;
    return Positioned(
      top: top,
      left: 0,
      right: 0,
      child: Container(height: 2, color: Theme.of(context).colorScheme.error),
    );
  }
}

Iterable<CalendarItem> _allDayItems(List<CalendarItem> items, DateTime date) {
  final navigation = CalendarNavigationController(selectedDate: date);
  final result = navigation
      .eventsForDate(items, date)
      .where((item) => item.allDay)
      .toList(growable: false);
  navigation.dispose();
  return result;
}

String _eventTime(BuildContext context, CalendarItem item) {
  if (item.type == ItemType.task) {
    return '截止 ${formatTime(context, item.dueAt!)}';
  }
  final end = item.endAt;
  if (end == null) return formatTime(context, item.startAt!);
  return '${formatTime(context, item.startAt!)}–${formatTime(context, end)}';
}

bool _isSameDate(DateTime left, DateTime right) =>
    left.year == right.year &&
    left.month == right.month &&
    left.day == right.day;
