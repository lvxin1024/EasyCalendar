import 'package:easy_calendar/widget/widget_deep_link_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses widget today, due, and item links', () {
    final today = parseWidgetDeepLink('easycalendar://today');
    final due = parseWidgetDeepLink('easycalendar://due');
    final item = parseWidgetDeepLink('easycalendar://item/item_123');

    expect(today?.kind, WidgetDeepLinkKind.today);
    expect(today?.itemId, isNull);
    expect(due?.kind, WidgetDeepLinkKind.due);
    expect(due?.itemId, isNull);
    expect(item?.kind, WidgetDeepLinkKind.item);
    expect(item?.itemId, 'item_123');
  });

  test('rejects malformed or unrelated widget links', () {
    expect(parseWidgetDeepLink(null), isNull);
    expect(parseWidgetDeepLink('https://example.com/today'), isNull);
    expect(parseWidgetDeepLink('easycalendar://item'), isNull);
    expect(parseWidgetDeepLink('easycalendar://item/a/b'), isNull);
  });

  test('controller exposes each accepted target once', () {
    final controller = WidgetDeepLinkController();
    controller.handleUrl('easycalendar://item/item_456');

    expect(controller.takePendingTarget()?.itemId, 'item_456');
    expect(controller.takePendingTarget(), isNull);
  });
}
