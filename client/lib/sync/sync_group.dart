import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

enum SyncGroupRole { primary, replica }

enum SyncRelayMode { publicBestEffort, directOnly, custom }

class SyncGroupProfile {
  const SyncGroupProfile({
    required this.protocolVersion,
    required this.groupId,
    required this.groupSecret,
    required this.role,
    required this.primaryEndpointId,
    required this.endpointTicket,
    required this.relayMode,
    required this.relayUrls,
    required this.topologyEpoch,
  });

  factory SyncGroupProfile.createPrimary({
    required String primaryEndpointId,
    required String endpointTicket,
    SyncRelayMode relayMode = SyncRelayMode.publicBestEffort,
    List<String> relayUrls = const [],
    int topologyEpoch = 1,
    Random? random,
  }) {
    final source = random ?? Random.secure();
    final secret = List<int>.generate(32, (_) => source.nextInt(256));
    return SyncGroupProfile._fromSecretBytes(
      role: SyncGroupRole.primary,
      primaryEndpointId: primaryEndpointId,
      endpointTicket: endpointTicket,
      relayMode: relayMode,
      relayUrls: relayUrls,
      topologyEpoch: topologyEpoch,
      secretBytes: secret,
    );
  }

  factory SyncGroupProfile.fromSecret({
    required String groupSecret,
    required SyncGroupRole role,
    required String primaryEndpointId,
    required String endpointTicket,
    SyncRelayMode relayMode = SyncRelayMode.publicBestEffort,
    List<String> relayUrls = const [],
    int topologyEpoch = 1,
  }) {
    final secretBytes = _decodeSecret(groupSecret);
    return SyncGroupProfile._fromSecretBytes(
      role: role,
      primaryEndpointId: primaryEndpointId,
      endpointTicket: endpointTicket,
      relayMode: relayMode,
      relayUrls: relayUrls,
      topologyEpoch: topologyEpoch,
      secretBytes: secretBytes,
    );
  }

  factory SyncGroupProfile._fromJson(Map<String, Object?> json) {
    _validateKeys(json);
    final protocolVersion = json['protocol'];
    if (protocolVersion != 1) {
      throw const FormatException('同步组协议版本不受支持');
    }
    final groupSecret = json['group_secret'];
    final role = _parseRole(json['role']);
    final relayMode = _parseRelayMode(json['relay_mode']);
    final primaryEndpointId = _requiredId(json['primary_endpoint_id']);
    final endpointTicket = _requiredTicket(json['endpoint_ticket']);
    final relayUrls = _validateRelayUrls(json['relay_urls']);
    final topologyEpoch = json['topology_epoch'];
    if (topologyEpoch is! int || topologyEpoch < 1) {
      throw const FormatException('同步组拓扑版本无效');
    }
    final secretBytes = _decodeSecret(groupSecret);
    final expectedGroupId = _deriveGroupId(secretBytes);
    if (json['group_id'] != expectedGroupId) {
      throw const FormatException('同步组标识与密钥不匹配');
    }
    _validateRelayMode(relayMode, relayUrls);
    return SyncGroupProfile(
      protocolVersion: protocolVersion as int,
      groupId: expectedGroupId,
      groupSecret: _encodeSecret(secretBytes),
      role: role,
      primaryEndpointId: primaryEndpointId,
      endpointTicket: endpointTicket,
      relayMode: relayMode,
      relayUrls: List.unmodifiable(relayUrls),
      topologyEpoch: topologyEpoch,
    );
  }

  final int protocolVersion;
  final String groupId;
  final String groupSecret;
  final SyncGroupRole role;
  final String primaryEndpointId;
  final String endpointTicket;
  final SyncRelayMode relayMode;
  final List<String> relayUrls;
  final int topologyEpoch;

  Map<String, Object?> toJson() => {
    'protocol': protocolVersion,
    'group_id': groupId,
    'group_secret': groupSecret,
    'role': role.name,
    'primary_endpoint_id': primaryEndpointId,
    'endpoint_ticket': endpointTicket,
    'relay_mode': relayMode.name,
    'relay_urls': relayUrls,
    'topology_epoch': topologyEpoch,
  };

  String encode() => SyncGroupCode.encode(this);

  static SyncGroupProfile _fromSecretBytes({
    required SyncGroupRole role,
    required String primaryEndpointId,
    required String endpointTicket,
    required SyncRelayMode relayMode,
    required List<String> relayUrls,
    required int topologyEpoch,
    required List<int> secretBytes,
  }) {
    _requiredId(primaryEndpointId);
    _requiredTicket(endpointTicket);
    final validatedRelayUrls = _validateRelayUrls(relayUrls);
    if (topologyEpoch < 1) {
      throw const FormatException('同步组拓扑版本无效');
    }
    _validateRelayMode(relayMode, validatedRelayUrls);
    return SyncGroupProfile(
      protocolVersion: 1,
      groupId: _deriveGroupId(secretBytes),
      groupSecret: _encodeSecret(secretBytes),
      role: role,
      primaryEndpointId: primaryEndpointId.trim(),
      endpointTicket: endpointTicket.trim(),
      relayMode: relayMode,
      relayUrls: List.unmodifiable(validatedRelayUrls),
      topologyEpoch: topologyEpoch,
    );
  }

  static void _validateKeys(Map<String, Object?> json) {
    const expected = {
      'protocol',
      'group_id',
      'group_secret',
      'role',
      'primary_endpoint_id',
      'endpoint_ticket',
      'relay_mode',
      'relay_urls',
      'topology_epoch',
    };
    if (json.keys.length != expected.length ||
        !json.keys.every(expected.contains)) {
      throw const FormatException('同步组配置包含未知或缺失字段');
    }
  }

  static String _requiredId(Object? value) {
    final id = value is String ? value.trim() : '';
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$').hasMatch(id)) {
      throw const FormatException('同步组设备标识无效');
    }
    return id;
  }

  static String _requiredTicket(Object? value) {
    final ticket = value is String ? value.trim() : '';
    if (ticket.isEmpty || ticket.length > 8192) {
      throw const FormatException('同步组连接 ticket 无效');
    }
    return ticket;
  }

  static List<String> _validateRelayUrls(Object? value) {
    if (value is! List || value.length > 8) {
      throw const FormatException('同步组 relay 地址列表无效');
    }
    final urls = <String>[];
    for (final entry in value) {
      final url = entry is String ? entry.trim() : '';
      final uri = Uri.tryParse(url);
      if (url.isEmpty ||
          uri == null ||
          uri.scheme != 'https' ||
          !uri.hasAuthority ||
          uri.userInfo.isNotEmpty) {
        throw const FormatException('同步组 relay 地址必须是 HTTPS URL');
      }
      urls.add(url);
    }
    return urls;
  }

  static void _validateRelayMode(SyncRelayMode mode, List<String> relayUrls) {
    if (mode == SyncRelayMode.directOnly && relayUrls.isNotEmpty) {
      throw const FormatException('直连模式不能包含 relay 地址');
    }
    if (mode == SyncRelayMode.custom && relayUrls.isEmpty) {
      throw const FormatException('自定义 relay 模式至少需要一个地址');
    }
  }

  static SyncGroupRole _parseRole(Object? value) {
    for (final role in SyncGroupRole.values) {
      if (role.name == value) return role;
    }
    throw const FormatException('同步组角色无效');
  }

  static SyncRelayMode _parseRelayMode(Object? value) {
    for (final mode in SyncRelayMode.values) {
      if (mode.name == value) return mode;
    }
    throw const FormatException('同步组 relay 模式无效');
  }

  static List<int> _decodeSecret(Object? value) {
    if (value is! String || value.isEmpty || value.contains('=')) {
      throw const FormatException('同步组密钥格式无效');
    }
    try {
      final bytes = base64Url.decode(base64Url.normalize(value));
      if (bytes.length != 32) {
        throw const FormatException('同步组密钥必须是 32 字节');
      }
      return bytes;
    } catch (error) {
      if (error is FormatException) rethrow;
      throw const FormatException('同步组密钥格式无效');
    }
  }

  static String _encodeSecret(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  static String _deriveGroupId(List<int> secretBytes) => sha256.convert([
    ...utf8.encode('easycalendar.sync.group.v1\u0000'),
    ...secretBytes,
  ]).toString();
}

class SyncGroupCode {
  const SyncGroupCode._();

  static const prefix = 'ECG1-';

  static String encode(SyncGroupProfile profile) {
    final json = profile.toJson();
    final canonical = _canonicalJson(json);
    final payload = base64Url
        .encode(utf8.encode(canonical))
        .replaceAll('=', '');
    final checksum = base64Url
        .encode(sha256.convert(utf8.encode(canonical)).bytes)
        .replaceAll('=', '');
    return '$prefix$payload.$checksum';
  }

  static SyncGroupProfile decode(String input) {
    final code = input.trim();
    if (!code.startsWith(prefix) || code.length > 32768) {
      throw const FormatException('同步组配置码格式无效');
    }
    final parts = code.substring(prefix.length).split('.');
    if (parts.length != 2 || parts.any((part) => part.isEmpty)) {
      throw const FormatException('同步组配置码格式无效');
    }
    try {
      final canonical = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[0])),
      );
      final expectedChecksum = base64Url
          .encode(sha256.convert(utf8.encode(canonical)).bytes)
          .replaceAll('=', '');
      if (parts[1] != expectedChecksum) {
        throw const FormatException('同步组配置码校验失败');
      }
      final decoded = jsonDecode(canonical);
      if (decoded is! Map) {
        throw const FormatException('同步组配置码内容无效');
      }
      return SyncGroupProfile._fromJson(
        decoded.map<String, Object?>((key, value) => MapEntry('$key', value)),
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('同步组配置码格式无效');
    }
  }

  static String _canonicalJson(Object? value) {
    if (value is Map) {
      final entries = value.entries.toList()
        ..sort((left, right) => '${left.key}'.compareTo('${right.key}'));
      return '{${entries.map((entry) => '${jsonEncode('${entry.key}')}:'
          '${_canonicalJson(entry.value)}').join(',')}}';
    }
    if (value is List) {
      return '[${value.map(_canonicalJson).join(',')}]';
    }
    return jsonEncode(value);
  }
}
