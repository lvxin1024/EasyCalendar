import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class DesktopWindowController extends ChangeNotifier {
  DesktopWindowController({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('io.easycalendar/window');

  final MethodChannel _channel;
  double _opacity = 1;
  bool _alwaysOnTop = false;
  bool _interactionLocked = false;

  bool get available => Platform.isMacOS || Platform.isWindows;
  double get opacity => _opacity;
  bool get alwaysOnTop => _alwaysOnTop;
  bool get interactionLocked => _interactionLocked;

  Future<void> initialize({
    required double opacity,
    required bool alwaysOnTop,
  }) async {
    _opacity = normalizeWindowOpacity(opacity);
    _alwaysOnTop = alwaysOnTop;
    if (!available) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'windowInteractionUnlocked') {
        _interactionLocked = false;
        notifyListeners();
      }
    });
    await _channel.invokeMethod<void>('setOpacity', {'opacity': _opacity});
    await _channel.invokeMethod<void>('setAlwaysOnTop', {
      'value': _alwaysOnTop,
    });
  }

  Future<void> setOpacity(double value) async {
    _opacity = normalizeWindowOpacity(value);
    notifyListeners();
    if (available) {
      await _channel.invokeMethod<void>('setOpacity', {'opacity': _opacity});
    }
  }

  Future<void> setAlwaysOnTop(bool value) async {
    _alwaysOnTop = value;
    notifyListeners();
    if (available) {
      await _channel.invokeMethod<void>('setAlwaysOnTop', {'value': value});
    }
  }

  Future<void> setInteractionLocked(bool value) async {
    _interactionLocked = value;
    notifyListeners();
    if (available) {
      await _channel.invokeMethod<void>('setInteractionLocked', {
        'value': value,
      });
    }
  }
}

double normalizeWindowOpacity(double value) => value.clamp(0.2, 1.0).toDouble();
