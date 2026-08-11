import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../application/item_controller.dart';
import '../../domain/item.dart';
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final materialIndex = MaterialLocalizations.of(context).firstDayOfWeekIndex;
    widget.navigation.updateFirstDayOfWeek(
      materialWeekdayToDateTime(materialIndex),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.navigation,
    builder: (context, _) {
      final events = widget.navigation.eventsInRange(widget.controller.items);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CalendarToolbar(navigation: widget.navigation),
          const Divider(),
          Expanded(
            child: widget.navigation.mode == CalendarViewMode.month
                ? CalendarMonthGrid(
                    navigation: widget.navigation,
                    items: widget.controller.items,
                    onEdit: widget.onEdit,
                  )
                : CalendarTimeGrid(
                    dates: widget.navigation.visibleDates,
                    items: events,
                    selectedDate: widget.navigation.selectedDate,
                    hourHeight: _hourHeight,
                    onHourHeightChanged: (value) =>
                        setState(() => _hourHeight = value.clamp(48, 120)),
                    onDateSelected: widget.navigation.selectDate,
                    onEdit: widget.onEdit,
                  ),
          ),
        ],
      );
    },
  );
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
              _rangeTitle(navigation),
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
  CalendarNavigationController navigation,
) => switch (navigation.mode) {
  CalendarViewMode.day => DateFormat(
    'yyyy年M月d日 EEEE',
    'zh_CN',
  ).format(navigation.selectedDate),
  CalendarViewMode.week =>
    '${DateFormat('M月d日', 'zh_CN').format(navigation.rangeStart)}'
        ' - '
        '${DateFormat('M月d日', 'zh_CN').format(navigation.rangeEnd.subtract(const Duration(days: 1)))}',
  CalendarViewMode.month => DateFormat(
    'yyyy年M月',
    'zh_CN',
  ).format(navigation.selectedDate),
};

String _periodLabel(CalendarViewMode mode) => switch (mode) {
  CalendarViewMode.day => '天',
  CalendarViewMode.week => '周',
  CalendarViewMode.month => '月',
};
