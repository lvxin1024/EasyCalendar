import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/cycle_prediction.dart';
import '../../domain/item.dart';
import '../../utils/configured_time.dart';
import '../../utils/date_formatters.dart';
import '../../utils/tag_colors.dart';
import 'calendar_navigation_controller.dart';
import 'cycle_day_marker.dart';

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
    this.collectionColors = const {},
    required this.selectedDate,
    required this.hourHeight,
    required this.onHourHeightChanged,
    required this.onDateSelected,
    required this.onEdit,
    required this.onCreateTimedEvent,
    this.cycleStates = const {},
    this.showCycleMarkers = false,
  });

  final List<DateTime> dates;
  final List<CalendarItem> items;
  final List<CalendarItem> dueItems;
  final Map<String, int> tagColors;
  final Map<String, int> collectionColors;
  final DateTime selectedDate;
  final double hourHeight;
  final ValueChanged<double> onHourHeightChanged;
  final ValueChanged<DateTime> onDateSelected;
  final ValueChanged<CalendarItem> onEdit;
  final Future<void> Function(DateTime) onCreateTimedEvent;
  final Map<DateTime, CycleDayState> cycleStates;
  final bool showCycleMarkers;

  @override
  State<CalendarTimeGrid> createState() => _CalendarTimeGridState();
}

class _CalendarTimeGridState extends State<CalendarTimeGrid> {
  final _verticalController = ScrollController();
  final _horizontalController = ScrollController();
  final _headerHorizontalController = ScrollController();
  final Map<int, Offset> _activePointers = {};
  double? _pinchStartDistance;
  double? _pinchStartHourHeight;
  bool _syncingHorizontal = false;

  @override
  void initState() {
    super.initState();
    _horizontalController.addListener(_syncHeaderHorizontalOffset);
    _headerHorizontalController.addListener(_syncBodyHorizontalOffset);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollToWorkingHours(),
    );
  }

  @override
  void dispose() {
    _horizontalController.removeListener(_syncHeaderHorizontalOffset);
    _headerHorizontalController.removeListener(_syncBodyHorizontalOffset);
    _verticalController.dispose();
    _horizontalController.dispose();
    _headerHorizontalController.dispose();
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
            final dateColumnWidth = calendarDateColumnWidth(
              dateCount: widget.dates.length,
              availableWidth: constraints.maxWidth,
              platform: defaultTargetPlatform,
            );
            final width = 48.0 + dateColumnWidth * widget.dates.length;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Scrollbar(
                  controller: _headerHorizontalController,
                  notificationPredicate: (notification) =>
                      notification.metrics.axis == Axis.horizontal,
                  child: SingleChildScrollView(
                    controller: _headerHorizontalController,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: width,
                      child: Column(
                        children: [
                          _DateHeader(
                            dates: widget.dates,
                            selectedDate: widget.selectedDate,
                            onDateSelected: widget.onDateSelected,
                            cycleStates: widget.cycleStates,
                            showCycleMarkers: widget.showCycleMarkers,
                          ),
                          _AllDayRow(
                            dates: widget.dates,
                            items: widget.items,
                            tagColors: widget.tagColors,
                            collectionColors: widget.collectionColors,
                            onEdit: widget.onEdit,
                          ),
                          const Divider(height: 1),
                        ],
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Stack(
                    children: [
                      Listener(
                        onPointerSignal: _handlePointerSignal,
                        onPointerDown: _handlePointerDown,
                        onPointerMove: _handlePointerMove,
                        onPointerUp: _handlePointerUp,
                        onPointerCancel: _handlePointerCancel,
                        child: Scrollbar(
                          controller: _horizontalController,
                          notificationPredicate: (notification) =>
                              notification.metrics.axis == Axis.horizontal,
                          child: SingleChildScrollView(
                            controller: _horizontalController,
                            scrollDirection: Axis.horizontal,
                            child: SizedBox(
                              width: width,
                              height: constraints.maxHeight,
                              child: Scrollbar(
                                controller: _verticalController,
                                thumbVisibility: true,
                                child: SingleChildScrollView(
                                  controller: _verticalController,
                                  padding: const EdgeInsets.only(bottom: 96),
                                  child: SizedBox(
                                    height: widget.hourHeight * 24,
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const SizedBox(width: 48),
                                        for (
                                          var dateIndex = 0;
                                          dateIndex < widget.dates.length;
                                          dateIndex++
                                        )
                                          SizedBox(
                                            width: dateColumnWidth,
                                            child: _DayColumn(
                                              date: widget.dates[dateIndex],
                                              dates: widget.dates,
                                              dateIndex: dateIndex,
                                              columnWidth: dateColumnWidth,
                                              items: widget.items,
                                              dueItems: widget.dueItems,
                                              tagColors: widget.tagColors,
                                              collectionColors:
                                                  widget.collectionColors,
                                              hourHeight: widget.hourHeight,
                                              onEdit: widget.onEdit,
                                              onCreateTimedEvent:
                                                  widget.onCreateTimedEvent,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      _stickyTimeGutter(),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ],
  );

  void _syncHeaderHorizontalOffset() =>
      _syncHorizontalOffset(_horizontalController, _headerHorizontalController);

  void _syncBodyHorizontalOffset() =>
      _syncHorizontalOffset(_headerHorizontalController, _horizontalController);

  void _syncHorizontalOffset(ScrollController source, ScrollController target) {
    if (_syncingHorizontal || !source.hasClients || !target.hasClients) return;
    final offset = source.offset
        .clamp(0.0, target.position.maxScrollExtent)
        .toDouble();
    if ((target.offset - offset).abs() < 0.5) return;
    _syncingHorizontal = true;
    target.jumpTo(offset);
    _syncingHorizontal = false;
  }

  Widget _stickyTimeGutter() {
    final colorScheme = Theme.of(context).colorScheme;
    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      width: 48,
      child: IgnorePointer(
        child: ClipRect(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colorScheme.surface,
              border: Border(
                right: BorderSide(color: colorScheme.outlineVariant),
              ),
            ),
            child: AnimatedBuilder(
              animation: _verticalController,
              builder: (context, child) {
                final offset = _verticalController.hasClients
                    ? _verticalController.offset
                    : 0.0;
                return Transform.translate(
                  offset: Offset(0, -offset),
                  child: child,
                );
              },
              child: SizedBox(
                height: widget.hourHeight * 24,
                child: _TimeGutter(hourHeight: widget.hourHeight),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final keyboard = HardwareKeyboard.instance;
    if (!keyboard.isMetaPressed && !keyboard.isControlPressed) return;
    widget.onHourHeightChanged(
      (widget.hourHeight - event.scrollDelta.dy * 0.12).clamp(16, 120),
    );
  }

  void _handlePointerDown(PointerDownEvent event) {
    _activePointers[event.pointer] = event.localPosition;
    if (_activePointers.length != 2) return;
    _pinchStartDistance = _pointerDistance();
    _pinchStartHourHeight = widget.hourHeight;
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (!_activePointers.containsKey(event.pointer)) return;
    _activePointers[event.pointer] = event.localPosition;
    final startDistance = _pinchStartDistance;
    final startHourHeight = _pinchStartHourHeight;
    if (startDistance == null ||
        startDistance <= 0 ||
        startHourHeight == null) {
      return;
    }
    final distance = _pointerDistance();
    if (distance <= 0) return;
    widget.onHourHeightChanged(
      (startHourHeight * distance / startDistance).clamp(16, 120),
    );
  }

  void _handlePointerUp(PointerUpEvent event) {
    _activePointers.remove(event.pointer);
    _resetPinchIfNeeded();
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    _activePointers.remove(event.pointer);
    _resetPinchIfNeeded();
  }

  void _resetPinchIfNeeded() {
    if (_activePointers.length < 2) {
      _pinchStartDistance = null;
      _pinchStartHourHeight = null;
    }
  }

  double _pointerDistance() {
    if (_activePointers.length < 2) return 0;
    final positions = _activePointers.values.take(2).toList(growable: false);
    return (positions[0] - positions[1]).distance;
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

@visibleForTesting
double calendarDateColumnWidth({
  required int dateCount,
  required double availableWidth,
  required TargetPlatform platform,
}) {
  const gutterWidth = 48.0;
  const compactColumnWidth = 72.0;
  if (dateCount <= 1) {
    return math.max(210, availableWidth - gutterWidth);
  }
  final desktop =
      platform == TargetPlatform.macOS || platform == TargetPlatform.windows;
  if (!desktop) return compactColumnWidth;
  return math.max(
    compactColumnWidth,
    (availableWidth - gutterWidth) / dateCount,
  );
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
    required this.cycleStates,
    required this.showCycleMarkers,
  });

  final List<DateTime> dates;
  final DateTime selectedDate;
  final ValueChanged<DateTime> onDateSelected;
  final Map<DateTime, CycleDayState> cycleStates;
  final bool showCycleMarkers;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: showCycleMarkers ? 34 : 30,
    child: Row(
      children: [
        const SizedBox(width: 48),
        for (final date in dates)
          Expanded(
            child: InkWell(
              onTap: () => onDateSelected(date),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: _isSameDate(date, selectedDate)
                      ? Theme.of(context).colorScheme.primaryContainer
                      : null,
                  border: Border(
                    left: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          formatCompactDateWithWeekday(context, date),
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ),
                      if (showCycleMarkers)
                        SizedBox(
                          height: 4,
                          child:
                              cycleStates[DateTime(
                                    date.year,
                                    date.month,
                                    date.day,
                                  )] ==
                                  null
                              ? null
                              : CycleDayMarker(
                                  state:
                                      cycleStates[DateTime(
                                        date.year,
                                        date.month,
                                        date.day,
                                      )]!,
                                  height: 4,
                                ),
                        ),
                    ],
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
    required this.tagColors,
    required this.collectionColors,
    required this.onEdit,
  });

  final List<DateTime> dates;
  final List<CalendarItem> items;
  final Map<String, int> tagColors;
  final Map<String, int> collectionColors;
  final ValueChanged<CalendarItem> onEdit;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 22, maxHeight: 36),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(
          width: 48,
          child: Center(child: Text('全天', style: TextStyle(fontSize: 11))),
        ),
        for (final date in dates)
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final item in _allDayItems(items, date).take(2))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 1),
                        child: _AllDayEvent(
                          item: item,
                          tagColors: tagColors,
                          collectionColors: collectionColors,
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
  const _AllDayEvent({
    required this.item,
    required this.tagColors,
    required this.collectionColors,
    required this.onTap,
  });

  final CalendarItem item;
  final Map<String, int> tagColors;
  final Map<String, int> collectionColors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final accent = colorForItemAccent(
      collectionId: item.collectionId,
      tags: item.tags,
      tagColors: tagColors,
      collectionColors: collectionColors,
    );
    return Material(
      color: Color.alphaBlend(accent.withAlpha(44), colorScheme.surface),
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Row(
          children: [
            Container(width: 3, color: accent),
            Expanded(
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
          ],
        ),
      ),
    );
  }
}

class _TimeGutter extends StatelessWidget {
  const _TimeGutter({required this.hourHeight});

  final double hourHeight;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 48,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        for (var hour = 0; hour < 24; hour += 1)
          Positioned(
            top: hour * hourHeight - 7,
            left: 0,
            right: 8,
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(
                formatHourLabel(context, hour),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _DayColumn extends StatefulWidget {
  const _DayColumn({
    required this.date,
    required this.dates,
    required this.dateIndex,
    required this.columnWidth,
    required this.items,
    required this.dueItems,
    required this.tagColors,
    required this.collectionColors,
    required this.hourHeight,
    required this.onEdit,
    required this.onCreateTimedEvent,
  });

  final DateTime date;
  final List<DateTime> dates;
  final int dateIndex;
  final double columnWidth;
  final List<CalendarItem> items;
  final List<CalendarItem> dueItems;
  final Map<String, int> tagColors;
  final Map<String, int> collectionColors;
  final double hourHeight;
  final ValueChanged<CalendarItem> onEdit;
  final Future<void> Function(DateTime) onCreateTimedEvent;

  @override
  State<_DayColumn> createState() => _DayColumnState();
}

class _DayColumnState extends State<_DayColumn> {
  int? _previewStartMinutes;
  double _previewDragDx = 0;
  double _dragOriginX = 0;

  @override
  Widget build(BuildContext context) {
    final placements = layoutTimedEvents(
      widget.items,
      widget.date,
      dueItems: widget.dueItems,
    );
    return LayoutBuilder(
      builder: (context, constraints) => DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (var hour = 0; hour < 24; hour += 1)
              Positioned(
                top: hour * widget.hourHeight,
                left: 0,
                right: 0,
                child: Divider(
                  height: 1,
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
            if (_isSameDate(widget.date, configuredNow()))
              _CurrentTimeLine(hourHeight: widget.hourHeight),
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onLongPressStart: (details) =>
                    _beginDrag(details.localPosition),
                onLongPressMoveUpdate: (details) =>
                    _updateDrag(details.localPosition),
                onLongPressEnd: (_) => _finishDrag(),
                onLongPressCancel: _clearPreview,
                child: const SizedBox.expand(),
              ),
            ),
            if (_previewStartMinutes != null)
              _PreviewEvent(
                startMinutes: _previewStartMinutes!,
                hourHeight: widget.hourHeight,
                width: constraints.maxWidth,
                horizontalOffset: _previewDragDx,
              ),
            if (_previewStartMinutes != null)
              _PreviewTimeLabel(
                startMinutes: _previewStartMinutes!,
                hourHeight: widget.hourHeight,
                horizontalOffset: _previewDragDx,
              ),
            for (final placement in placements)
              _PositionedEvent(
                placement: placement,
                availableWidth: constraints.maxWidth,
                hourHeight: widget.hourHeight,
                tagColors: widget.tagColors,
                collectionColors: widget.collectionColors,
                onTap: () => widget.onEdit(placement.item),
              ),
            if (_isSameDate(widget.date, configuredNow()))
              _CurrentTimeLine(hourHeight: widget.hourHeight),
          ],
        ),
      ),
    );
  }

  void _beginDrag(Offset position) {
    _dragOriginX = position.dx;
    setState(() {
      _previewStartMinutes = snapTimelineMinutes(
        position.dy,
        widget.hourHeight,
      );
      _previewDragDx = 0;
    });
  }

  void _updateDrag(Offset position) {
    if (_previewStartMinutes == null) return;
    setState(() {
      _previewStartMinutes = snapTimelineMinutes(
        position.dy,
        widget.hourHeight,
      );
      _previewDragDx = position.dx - _dragOriginX;
    });
  }

  Future<void> _finishDrag() async {
    if (_previewStartMinutes == null) return;
    final shift = (_previewDragDx / widget.columnWidth).round();
    final targetIndex = (widget.dateIndex + shift).clamp(
      0,
      widget.dates.length - 1,
    );
    await _commitPreview(targetIndex);
  }

  Future<void> _commitPreview(int targetIndex) async {
    final startMinutes = _previewStartMinutes;
    if (startMinutes == null) return;
    final start = timelineDateTimeForOffset(
      widget.dates[targetIndex],
      startMinutes / 60 * widget.hourHeight,
      widget.hourHeight,
    );
    try {
      // Let the snapped block and gutter marker render before navigation.
      await Future<void>.delayed(const Duration(milliseconds: 220));
      if (!mounted) return;
      await widget.onCreateTimedEvent(start);
    } finally {
      if (mounted) _clearPreview();
    }
  }

  void _clearPreview() {
    if (!mounted || _previewStartMinutes == null) return;
    setState(() {
      _previewStartMinutes = null;
      _previewDragDx = 0;
    });
  }
}

class _PreviewEvent extends StatelessWidget {
  const _PreviewEvent({
    required this.startMinutes,
    required this.hourHeight,
    required this.width,
    required this.horizontalOffset,
  });

  final int startMinutes;
  final double hourHeight;
  final double width;
  final double horizontalOffset;

  @override
  Widget build(BuildContext context) {
    final top = startMinutes / 60 * hourHeight;
    return Positioned(
      top: top + 1,
      left: 3 + horizontalOffset,
      width: math.max(8, width - 6),
      height: math.max(24, hourHeight - 2),
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.primaryContainer.withAlpha(210),
            border: Border.all(color: Theme.of(context).colorScheme.primary),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            child: Text(
              '新建日程 · ${_formatPreviewTime(startMinutes)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewTimeLabel extends StatelessWidget {
  const _PreviewTimeLabel({
    required this.startMinutes,
    required this.hourHeight,
    required this.horizontalOffset,
  });

  final int startMinutes;
  final double hourHeight;
  final double horizontalOffset;

  @override
  Widget build(BuildContext context) => Positioned(
    top: startMinutes / 60 * hourHeight - 9,
    left: -47 + horizontalOffset,
    width: 44,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
        child: Text(
          _formatPreviewTime(startMinutes),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: Theme.of(context).colorScheme.onPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    ),
  );
}

String _formatPreviewTime(int minutes) =>
    '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';

class _PositionedEvent extends StatelessWidget {
  const _PositionedEvent({
    required this.placement,
    required this.availableWidth,
    required this.hourHeight,
    required this.tagColors,
    required this.collectionColors,
    required this.onTap,
  });

  final CalendarEventPlacement placement;
  final double availableWidth;
  final double hourHeight;
  final Map<String, int> tagColors;
  final Map<String, int> collectionColors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isTask = placement.item.type == ItemType.task;
    final accent = isTask
        ? colorScheme.tertiary
        : colorForItemAccent(
            collectionId: placement.item.collectionId,
            tags: placement.item.tags,
            tagColors: tagColors,
            collectionColors: collectionColors,
          );
    final background = isTask
        ? colorScheme.tertiaryContainer
        : Color.alphaBlend(accent.withAlpha(44), colorScheme.surface);
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
        color: background,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 3, color: accent),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 3,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isTask
                            ? 'Due · ${placement.item.title}'
                            : placement.item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: colorScheme.onSurface,
                            ),
                      ),
                      if (rawHeight >= 38)
                        Text(
                          _eventTime(context, placement.item),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                    ],
                  ),
                ),
              ),
            ],
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
    final color = Theme.of(context).colorScheme.tertiary;
    return Positioned(
      top: top,
      left: 0,
      right: 0,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(left: 1, top: 1),
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 2),
          Expanded(
            child: Container(
              height: 2,
              margin: const EdgeInsets.only(top: 4),
              color: color,
            ),
          ),
        ],
      ),
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

/// Rounds a timeline tap to the nearest quarter hour and keeps it within the
/// last hour that can still host a one-hour event on the same day.
int snapTimelineMinutes(double localY, double hourHeight) {
  if (hourHeight <= 0) return 0;
  final rawMinutes = (localY / hourHeight * 60).round();
  final snapped = ((rawMinutes + 7) ~/ 15) * 15;
  return snapped.clamp(0, 23 * 60);
}

DateTime timelineDateTimeForOffset(
  DateTime date,
  double localY,
  double hourHeight,
) {
  final minutes = snapTimelineMinutes(localY, hourHeight);
  return configuredDateTime(
    year: date.year,
    month: date.month,
    day: date.day,
    hour: minutes ~/ 60,
    minute: minutes % 60,
  );
}

bool _isSameDate(DateTime left, DateTime right) =>
    left.year == right.year &&
    left.month == right.month &&
    left.day == right.day;
