import 'package:flutter/material.dart';

import '../../domain/china_holiday.dart';

class CalendarDateLabel extends StatelessWidget {
  const CalendarDateLabel({super.key, required this.date, required this.child});

  final DateTime date;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final adjustment = chinaDayAdjustment(date);
    if (adjustment == null) return child;
    final isRest = adjustment == ChinaDayAdjustment.rest;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: const EdgeInsets.only(top: 3), child: child),
        Padding(
          padding: const EdgeInsets.only(left: 2),
          child: Text(
            isRest ? '休' : '工',
            semanticsLabel: isRest ? '休息日' : '调休工作日',
            style: TextStyle(
              color: Theme.of(context).brightness == Brightness.dark
                  ? const Color(0xFFFF8A80)
                  : const Color(0xFFC62828),
              fontSize: 10,
              height: 1,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
