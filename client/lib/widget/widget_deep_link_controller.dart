import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum WidgetDeepLinkKind { today, due, item, complete }

class WidgetDeepLinkTarget {
  const WidgetDeepLinkTarget.today()
    : kind = WidgetDeepLinkKind.today,
      itemId = null;

  const WidgetDeepLinkTarget.due()
    : kind = WidgetDeepLinkKind.due,
      itemId = null;

  const WidgetDeepLinkTarget.item(this.itemId) : kind = WidgetDeepLinkKind.item;

  const WidgetDeepLinkTarget.complete(this.itemId)
    : kind = WidgetDeepLinkKind.complete;

  final WidgetDeepLinkKind kind;
  final String? itemId;
}

class WidgetDeepLinkController extends ChangeNotifier {
  WidgetDeepLinkController({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('io.easycalendar/widget');

  final MethodChannel _channel;
  WidgetDeepLinkTarget? _pendingTarget;

  Future<void> start() async {
    if (!Platform.isMacOS && !Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'openWidgetTarget') {
        handleUrl(call.arguments as String?);
      }
    });
    await _channel.invokeMethod<void>('readyForWidgetLinks');
  }

  WidgetDeepLinkTarget? takePendingTarget() {
    final target = _pendingTarget;
    _pendingTarget = null;
    return target;
  }

  @visibleForTesting
  void handleUrl(String? value) {
    final target = parseWidgetDeepLink(value);
    if (target == null) return;
    _pendingTarget = target;
    notifyListeners();
  }
}

@visibleForTesting
WidgetDeepLinkTarget? parseWidgetDeepLink(String? value) {
  if (value == null) return null;
  final uri = Uri.tryParse(value);
  if (uri == null || uri.scheme != 'easycalendar') return null;
  if (uri.host == 'today' && uri.pathSegments.isEmpty) {
    return const WidgetDeepLinkTarget.today();
  }
  if (uri.host == 'due' && uri.pathSegments.isEmpty) {
    return const WidgetDeepLinkTarget.due();
  }
  if (uri.host == 'item' && uri.pathSegments.length == 1) {
    final itemId = uri.pathSegments.single;
    if (itemId.isNotEmpty) return WidgetDeepLinkTarget.item(itemId);
  }
  if (uri.host == 'complete' && uri.pathSegments.length == 1) {
    final itemId = uri.pathSegments.single;
    if (itemId.isNotEmpty) return WidgetDeepLinkTarget.complete(itemId);
  }
  return null;
}
