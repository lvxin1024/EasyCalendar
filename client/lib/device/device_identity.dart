import 'dart:io';

import 'package:uuid/uuid.dart';

class DeviceIdentity {
  DeviceIdentity({String Function()? idGenerator, String? platformLabel})
    : _idGenerator = idGenerator ?? (() => 'device-${Uuid().v4()}'),
      _platformLabel = platformLabel ?? _defaultPlatformLabel();

  static const legacyDefaultId = 'my-easycalendar-client';
  static final _validId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{1,127}$');

  final String Function() _idGenerator;
  final String _platformLabel;

  String resolveInitialId(String configuredId) {
    final normalized = configuredId.trim();
    return _shouldReplace(normalized) ? generateId() : normalized;
  }

  String ensurePersistedId(String storedId, {required String fallbackId}) {
    final normalized = storedId.trim();
    if (!_shouldReplace(normalized)) return normalized;

    final fallback = fallbackId.trim();
    if (!_shouldReplace(fallback)) return fallback;
    return generateId();
  }

  String generateId() {
    final generated = _idGenerator().trim();
    if (_shouldReplace(generated)) {
      throw StateError('Device ID generator returned an invalid ID.');
    }
    return generated;
  }

  String generateDistinctId(String currentId) {
    for (var attempt = 0; attempt < 3; attempt += 1) {
      final generated = generateId();
      if (generated != currentId.trim()) return generated;
    }
    throw StateError('Device ID generator repeatedly returned the current ID.');
  }

  String ensureDeviceName(String storedName, {required String deviceId}) {
    final normalized = storedName.trim();
    if (normalized.isNotEmpty) return normalized;
    final suffix = deviceId.length <= 6
        ? deviceId
        : deviceId.substring(deviceId.length - 6);
    return '$_platformLabel-$suffix';
  }

  static bool isValid(String value) => _validId.hasMatch(value.trim());

  static bool _shouldReplace(String value) =>
      value.isEmpty || value == legacyDefaultId || !_validId.hasMatch(value);

  static String _defaultPlatformLabel() {
    if (Platform.isMacOS) return 'Mac';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isAndroid) return 'Android';
    return 'Device';
  }
}
