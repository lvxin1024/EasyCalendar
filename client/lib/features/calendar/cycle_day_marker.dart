import 'package:flutter/material.dart';

import '../../domain/cycle_prediction.dart';

class CycleDayMarker extends StatelessWidget {
  const CycleDayMarker({
    super.key,
    required this.state,
    this.width = 20,
    this.height = 4,
  });

  final CycleDayState state;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final recorded = state.kind == CycleDayKind.recorded;
    return Semantics(
      label: recorded
          ? '已记录经期'
          : state.isCenter
          ? '预计经期开始'
          : '预测经期',
      child: SizedBox(
        width: width,
        height: height,
        child: CustomPaint(
          painter: _CycleMarkerPainter(
            color: recorded ? const Color(0xFFA33F49) : const Color(0xFFE8B9C0),
            dashed: !recorded,
            center: state.isCenter,
          ),
        ),
      ),
    );
  }
}

class CycleMarkerLegend extends StatelessWidget {
  const CycleMarkerLegend({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    label: '经期标记图例',
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CycleDayMarker(
          state: CycleDayState(
            kind: CycleDayKind.recorded,
            isStart: false,
            isEnd: false,
            isCenter: false,
          ),
        ),
        SizedBox(width: 5),
        Text('经期记录', style: TextStyle(fontSize: 11)),
        SizedBox(width: 12),
        CycleDayMarker(
          state: CycleDayState(
            kind: CycleDayKind.predicted,
            isStart: false,
            isEnd: false,
            isCenter: false,
          ),
        ),
        SizedBox(width: 5),
        Text('经期预测', style: TextStyle(fontSize: 11)),
      ],
    ),
  );
}

class _CycleMarkerPainter extends CustomPainter {
  const _CycleMarkerPainter({
    required this.color,
    required this.dashed,
    required this.center,
  });

  final Color color;
  final bool dashed;
  final bool center;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = center ? 3 : 2.5
      ..strokeCap = StrokeCap.round;
    final y = size.height / 2;
    if (!dashed) {
      canvas.drawLine(Offset(1, y), Offset(size.width - 1, y), paint);
      return;
    }
    const dash = 3.0;
    const gap = 2.0;
    for (var x = 1.0; x < size.width - 1; x += dash + gap) {
      canvas.drawLine(
        Offset(x, y),
        Offset((x + dash).clamp(0, size.width - 1), y),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_CycleMarkerPainter oldDelegate) =>
      color != oldDelegate.color ||
      dashed != oldDelegate.dashed ||
      center != oldDelegate.center;
}
