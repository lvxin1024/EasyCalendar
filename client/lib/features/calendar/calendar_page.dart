import 'package:flutter/material.dart';

import '../../application/item_controller.dart';
import '../../domain/item.dart';
import '../../utils/configured_time.dart';
import '../../utils/date_formatters.dart';
import 'calendar_navigation_controller.dart';
import 'calendar_month_grid.dart';
import 'calendar_time_grid.dart';

class CalendarPage extends StatefulWidget {
  const CalendarPage({
    super.key,
    required this.controller,
    required this.navigation,
    required this.onEdit,
    required this.onDelete,
    required this.onCreateTimedEvent,
    required this.onSync,
  });

  final ItemController controller;
  final CalendarNavigationController navigation;
  final ValueChanged<CalendarItem> onEdit;
  final ValueChanged<CalendarItem> onDelete;
  final Future<void> Function(DateTime) onCreateTimedEvent;
  final VoidCallback onSync;

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  double _hourHeight = 72;

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
        final events = widget.navigation.eventsInRange(widget.controller.items);
        final dues =
            widget.controller.items
                .where(
                  (item) =>
                      item.type == ItemType.task &&
                      item.status == ItemStatus.todo,
                )
                .toList(growable: false)
              ..sort((left, right) => left.dueAt!.compareTo(right.dueAt!));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _CalendarViewModeBar(
              navigation: widget.navigation,
              onSync: widget.onSync,
            ),
            if (dues.isNotEmpty)
              _PinnedDueStrip(items: dues, onEdit: widget.onEdit),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) {
                  final offset =
                      Tween<Offset>(
                        begin: const Offset(0.06, 0),
                        end: Offset.zero,
                      ).animate(
                        CurvedAnimation(
                          parent: animation,
                          curve: Curves.easeOut,
                        ),
                      );
                  return FadeTransition(
                    opacity: animation,
                    child: SlideTransition(position: offset, child: child),
                  );
                },
                child: NotificationListener<ScrollMetricsNotification>(
                  onNotification: _handleScrollMetrics,
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _handleScrollNotification,
                    child: Listener(
                      key: ValueKey(
                        '${widget.navigation.mode.name}-'
                        '${widget.navigation.rangeStart.toIso8601String()}',
                      ),
                      onPointerDown: _handleNavigationPointerDown,
                      onPointerUp: _handleNavigationPointerUp,
                      onPointerCancel: _handleNavigationPointerCancel,
                      child: widget.navigation.mode == CalendarViewMode.month
                          ? CalendarMonthGrid(
                              navigation: widget.navigation,
                              items: widget.navigation.calendarItemsInRange(
                                widget.controller.items,
                              ),
                              onEdit: widget.onEdit,
                              onDateSelected: _openDay,
                              tagColors:
                                  widget.controller.preferences.tagColors,
                            )
                          : CalendarTimeGrid(
                              dates: widget.navigation.visibleDates,
                              items: events,
                              dueItems: dues,
                              tagColors:
                                  widget.controller.preferences.tagColors,
                              selectedDate: widget.navigation.selectedDate,
                              hourHeight: _hourHeight,
                              onHourHeightChanged: (value) => setState(
                                () => _hourHeight = value.clamp(16, 120),
                              ),
                              onDateSelected: (date) =>
                                  widget.navigation.mode ==
                                      CalendarViewMode.week
                                  ? _openDay(date)
                                  : widget.navigation.selectDate(date),
                              onEdit: widget.onEdit,
                              onCreateTimedEvent: widget.onCreateTimedEvent,
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  final Map<int, ({Offset position, bool atStart, bool atEnd})>
  _navigationPointers = {};
  bool _atHorizontalStart = true;
  bool _atHorizontalEnd = false;

  void _handleNavigationPointerDown(PointerDownEvent event) {
    _navigationPointers[event.pointer] = (
      position: event.position,
      atStart: _atHorizontalStart,
      atEnd: _atHorizontalEnd,
    );
  }

  void _handleNavigationPointerUp(PointerUpEvent event) {
    final start = _navigationPointers.remove(event.pointer);
    if (start == null || _navigationPointers.isNotEmpty) return;
    final delta = event.position - start.position;
    final threshold = widget.navigation.mode == CalendarViewMode.day
        ? 48.0
        : 72.0;
    if (delta.dx.abs() < threshold || delta.dx.abs() < delta.dy.abs()) return;
    if (widget.navigation.mode != CalendarViewMode.day) {
      if (delta.dx > 0 && !start.atStart) return;
      if (delta.dx < 0 && !start.atEnd) return;
    }
    delta.dx > 0 ? widget.navigation.previous() : widget.navigation.next();
  }

  void _handleNavigationPointerCancel(PointerCancelEvent event) {
    _navigationPointers.remove(event.pointer);
  }

  bool _handleScrollMetrics(ScrollMetricsNotification notification) {
    _updateHorizontalEdges(notification.metrics);
    return false;
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    _updateHorizontalEdges(notification.metrics);
    return false;
  }

  void _updateHorizontalEdges(ScrollMetrics metrics) {
    if (metrics.axis != Axis.horizontal) return;
    const tolerance = 1.0;
    _atHorizontalStart = metrics.pixels <= metrics.minScrollExtent + tolerance;
    _atHorizontalEnd = metrics.pixels >= metrics.maxScrollExtent - tolerance;
  }

  void _openDay(DateTime date) {
    widget.navigation.selectDate(date);
    widget.navigation.setMode(CalendarViewMode.day);
  }
}

class _CalendarViewModeBar extends StatelessWidget {
  const _CalendarViewModeBar({required this.navigation, required this.onSync});

  final CalendarNavigationController navigation;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
    child: Row(
      children: [
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
        const Spacer(),
        IconButton(
          tooltip: '同步刷新',
          onPressed: onSync,
          icon: const Icon(Icons.sync),
        ),
      ],
    ),
  );
}

class _PinnedDueStrip extends StatelessWidget {
  const _PinnedDueStrip({required this.items, required this.onEdit});

  final List<CalendarItem> items;
  final ValueChanged<CalendarItem> onEdit;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(maxHeight: 62),
    padding: const EdgeInsets.fromLTRB(20, 4, 20, 5),
    color: Theme.of(context).colorScheme.errorContainer.withAlpha(90),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 3, right: 10),
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
