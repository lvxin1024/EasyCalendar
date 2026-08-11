import 'package:easy_calendar/window/desktop_window_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalizes desktop opacity to the readable range', () {
    expect(normalizeWindowOpacity(0), 0.2);
    expect(normalizeWindowOpacity(0.73), 0.73);
    expect(normalizeWindowOpacity(2), 1.0);
  });
}
