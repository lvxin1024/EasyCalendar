import 'package:easy_calendar/domain/cycle_prediction.dart';
import 'package:easy_calendar/features/calendar/cycle_day_marker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('uses distinct semantics for recorded and predicted markers', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              CycleDayMarker(
                state: CycleDayState(
                  kind: CycleDayKind.recorded,
                  isStart: true,
                  isEnd: false,
                  isCenter: false,
                ),
              ),
              CycleDayMarker(
                state: CycleDayState(
                  kind: CycleDayKind.predicted,
                  isStart: true,
                  isEnd: false,
                  isCenter: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.bySemanticsLabel('已记录经期'), findsOneWidget);
    expect(find.bySemanticsLabel('预计经期开始'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(CycleDayMarker),
        matching: find.byType(CustomPaint),
      ),
      findsNWidgets(2),
    );
    semantics.dispose();
  });
}
