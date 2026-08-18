import 'dart:convert';

import 'package:crypto/crypto.dart';

class CalendarConnectionCode {
  const CalendarConnectionCode({
    required this.collectionId,
    required this.name,
    this.color,
  });

  factory CalendarConnectionCode.decode(String input) {
    final code = input.trim();
    if (!code.startsWith(_prefix) || code.length > 4096) {
      throw const FormatException('日历配置码格式无效');
    }
    try {
      final encoded = code.substring(_prefix.length);
      final padded = encoded.padRight((encoded.length + 3) ~/ 4 * 4, '=');
      final envelope = jsonDecode(utf8.decode(base64Url.decode(padded)));
      if (envelope is! Map || envelope['data'] is! Map) {
        throw const FormatException('日历配置码内容无效');
      }
      final data = Map<String, dynamic>.from(envelope['data'] as Map);
      final canonical = jsonEncode(data);
      final expected = sha256
          .convert(utf8.encode(canonical))
          .toString()
          .substring(0, 16);
      if (envelope['checksum'] != expected) {
        throw const FormatException('日历配置码校验失败');
      }
      final validated = _validatedData(
        data['collection_id'],
        data['name'],
        data['color'],
      );
      return CalendarConnectionCode(
        collectionId: validated['collection_id']! as String,
        name: validated['name']! as String,
        color: validated['color'] as int?,
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('日历配置码格式无效');
    }
  }

  static const _prefix = 'ECAL1-';

  final String collectionId;
  final String name;
  final int? color;

  String encode() {
    final data = _validatedData(collectionId, name, color);
    final canonical = jsonEncode(data);
    final envelope = jsonEncode({
      'data': data,
      'checksum': sha256
          .convert(utf8.encode(canonical))
          .toString()
          .substring(0, 16),
    });
    return '$_prefix${base64Url.encode(utf8.encode(envelope)).replaceAll('=', '')}';
  }

  static Map<String, Object?> _validatedData(
    Object? collectionId,
    Object? name,
    Object? color,
  ) {
    final normalizedId = collectionId is String ? collectionId.trim() : '';
    final normalizedName = name is String ? name.trim() : '';
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$').hasMatch(normalizedId)) {
      throw const FormatException('日历配置码中的标识无效');
    }
    if (normalizedName.isEmpty || normalizedName.length > 80) {
      throw const FormatException('日历配置码中的名称无效');
    }
    if (color != null && (color is! int || color < 0 || color > 0xFFFFFFFF)) {
      throw const FormatException('日历配置码中的颜色无效');
    }
    return {
      'collection_id': normalizedId,
      'name': normalizedName,
      'color': color,
    };
  }
}
