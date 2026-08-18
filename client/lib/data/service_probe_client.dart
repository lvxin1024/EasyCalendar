import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

enum ServiceKind { sync, feature }

enum ServiceProbeFailureKind {
  invalidUrl,
  dns,
  tls,
  timeout,
  unauthorized,
  incompatibleVersion,
  missingCapability,
  server,
  invalidResponse,
  network,
}

class ServiceCapabilities {
  const ServiceCapabilities({
    required this.apiVersion,
    required this.features,
    required this.configured,
    required this.authenticationRequired,
    required this.authenticationScheme,
  });

  factory ServiceCapabilities.fromJson(Map<String, Object?> json) {
    final authentication = _object(json['authentication'], 'authentication');
    final required = authentication['required'];
    final scheme = authentication['scheme'];
    if (required is! bool || scheme is! String) {
      throw const FormatException('authentication 格式无效');
    }
    return ServiceCapabilities(
      apiVersion: json['api_version'] as String? ?? '',
      features: _boolMap(json['features'], 'features'),
      configured: _boolMap(json['configured'], 'configured'),
      authenticationRequired: required,
      authenticationScheme: scheme,
    );
  }

  final String apiVersion;
  final Map<String, bool> features;
  final Map<String, bool> configured;
  final bool authenticationRequired;
  final String authenticationScheme;

  bool supports(String feature) => features[feature] == true;
  bool isConfigured(String feature) => configured[feature] == true;

  static Map<String, Object?> _object(Object? value, String field) {
    if (value is! Map<Object?, Object?>) {
      throw FormatException('$field 必须是 JSON object');
    }
    return value.cast<String, Object?>();
  }

  static Map<String, bool> _boolMap(Object? value, String field) {
    final object = _object(value, field);
    final result = <String, bool>{};
    for (final entry in object.entries) {
      if (entry.value is! bool) {
        throw FormatException('$field.${entry.key} 必须是 boolean');
      }
      result[entry.key] = entry.value as bool;
    }
    return Map.unmodifiable(result);
  }
}

class ServiceProbeResult {
  const ServiceProbeResult({
    required this.kind,
    required this.serviceVersion,
    required this.schemaVersion,
    required this.capabilities,
  });

  final ServiceKind kind;
  final String serviceVersion;
  final int schemaVersion;
  final ServiceCapabilities capabilities;
}

class ServiceProbeClient {
  ServiceProbeClient({
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 10),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final Duration requestTimeout;

  Future<ServiceProbeResult> probe({
    required Uri serverUrl,
    required ServiceKind kind,
    String token = '',
  }) async {
    if (!serverUrl.hasAuthority ||
        (serverUrl.scheme != 'http' && serverUrl.scheme != 'https')) {
      throw const ServiceProbeException(
        ServiceProbeFailureKind.invalidUrl,
        '服务地址必须是有效的 HTTP(S) 地址。',
      );
    }

    final healthResponse = await _get(serverUrl.resolve('/v1/health'));
    _ensureSuccess(healthResponse);
    final health = _decodeObject(healthResponse.body, '健康检查');
    final serviceVersion = health['version'];
    final schemaVersion = health['schema_version'];
    if (health['status'] != 'ok' ||
        health['service'] != 'easycalendar' ||
        serviceVersion is! String ||
        serviceVersion.isEmpty ||
        schemaVersion is! int) {
      throw const ServiceProbeException(
        ServiceProbeFailureKind.invalidResponse,
        '健康检查响应不是有效的 EasyCalendar 服务。',
      );
    }

    final capabilitiesResponse = await _get(
      serverUrl.resolve('/v1/capabilities'),
    );
    _ensureSuccess(capabilitiesResponse);
    late final ServiceCapabilities capabilities;
    try {
      capabilities = ServiceCapabilities.fromJson(
        _decodeObject(capabilitiesResponse.body, '能力发现'),
      );
    } on FormatException {
      throw const ServiceProbeException(
        ServiceProbeFailureKind.incompatibleVersion,
        '服务版本过旧或能力响应不兼容，请升级服务端。',
      );
    }
    if (capabilities.apiVersion != 'v1' ||
        capabilities.authenticationScheme.toLowerCase() != 'bearer') {
      throw const ServiceProbeException(
        ServiceProbeFailureKind.incompatibleVersion,
        '服务 API 版本或鉴权方式不兼容。',
      );
    }

    _validateCapabilities(kind, capabilities);
    final normalizedToken = token.trim();
    if (capabilities.authenticationRequired && normalizedToken.isEmpty) {
      throw const ServiceProbeException(
        ServiceProbeFailureKind.unauthorized,
        '服务需要访问令牌，请先填写或保存令牌。',
      );
    }
    final authResponse = await _get(
      serverUrl.resolve('/v1/auth-check'),
      token: normalizedToken,
    );
    _ensureSuccess(authResponse, authCheck: true);

    return ServiceProbeResult(
      kind: kind,
      serviceVersion: serviceVersion,
      schemaVersion: schemaVersion,
      capabilities: capabilities,
    );
  }

  Future<http.Response> _get(Uri uri, {String token = ''}) async {
    try {
      return await _client
          .get(
            uri,
            headers: {
              'Accept': 'application/json',
              if (token.isNotEmpty) 'Authorization': 'Bearer $token',
            },
          )
          .timeout(requestTimeout);
    } on TimeoutException {
      throw const ServiceProbeException(
        ServiceProbeFailureKind.timeout,
        '连接超时，请检查服务地址和网络。',
      );
    } on HandshakeException catch (error) {
      throw ServiceProbeException(
        ServiceProbeFailureKind.tls,
        'TLS 证书或握手失败：${error.message}',
      );
    } on SocketException catch (error) {
      final kind = _looksLikeDnsFailure(error.message)
          ? ServiceProbeFailureKind.dns
          : ServiceProbeFailureKind.network;
      throw ServiceProbeException(
        kind,
        kind == ServiceProbeFailureKind.dns
            ? '无法解析服务域名，请检查地址或 DNS。'
            : '无法连接服务：${error.message}',
      );
    } on http.ClientException catch (error) {
      final message = error.message;
      final lower = message.toLowerCase();
      final kind = _looksLikeDnsFailure(message)
          ? ServiceProbeFailureKind.dns
          : (lower.contains('certificate') || lower.contains('handshake'))
          ? ServiceProbeFailureKind.tls
          : ServiceProbeFailureKind.network;
      throw ServiceProbeException(kind, switch (kind) {
        ServiceProbeFailureKind.dns => '无法解析服务域名，请检查地址或 DNS。',
        ServiceProbeFailureKind.tls => 'TLS 证书或握手失败：$message',
        _ => '无法连接服务：$message',
      });
    }
  }

  static void _validateCapabilities(
    ServiceKind kind,
    ServiceCapabilities capabilities,
  ) {
    if (kind == ServiceKind.sync) {
      if (!capabilities.supports('sync')) {
        throw const ServiceProbeException(
          ServiceProbeFailureKind.missingCapability,
          '该地址不是同步服务：服务未提供 sync 能力。',
        );
      }
      if (!capabilities.isConfigured('sync')) {
        throw const ServiceProbeException(
          ServiceProbeFailureKind.missingCapability,
          '同步服务存在，但服务端尚未启用 sync。',
        );
      }
      return;
    }
    if (!capabilities.supports('ics_subscriptions') &&
        !capabilities.supports('ics_transfer')) {
      throw const ServiceProbeException(
        ServiceProbeFailureKind.missingCapability,
        '该地址不是功能服务：未提供网址订阅等远程能力。',
      );
    }
  }

  static void _ensureSuccess(http.Response response, {bool authCheck = false}) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const ServiceProbeException(
        ServiceProbeFailureKind.unauthorized,
        '访问令牌无效或没有权限。',
      );
    }
    if (authCheck && response.statusCode == 404) {
      throw const ServiceProbeException(
        ServiceProbeFailureKind.incompatibleVersion,
        '服务版本过旧，不支持安全的鉴权检查。',
      );
    }
    if (response.statusCode == 426) {
      throw const ServiceProbeException(
        ServiceProbeFailureKind.incompatibleVersion,
        '服务端要求升级客户端或 API 版本。',
      );
    }
    if (response.statusCode >= 500) {
      throw ServiceProbeException(
        ServiceProbeFailureKind.server,
        '服务暂时不可用（HTTP ${response.statusCode}）。',
      );
    }
    throw ServiceProbeException(
      ServiceProbeFailureKind.invalidResponse,
      '服务返回了意外状态（HTTP ${response.statusCode}）。',
    );
  }

  static Map<String, Object?> _decodeObject(String value, String endpoint) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map<Object?, Object?>) {
        return decoded.cast<String, Object?>();
      }
    } catch (_) {
      // Report one stable error for malformed and non-object JSON responses.
    }
    throw ServiceProbeException(
      ServiceProbeFailureKind.invalidResponse,
      '$endpoint响应不是有效的 JSON object。',
    );
  }

  static bool _looksLikeDnsFailure(String message) {
    final normalized = message.toLowerCase();
    return normalized.contains('failed host lookup') ||
        normalized.contains('name or service not known') ||
        normalized.contains('nodename nor servname');
  }

  void close() => _client.close();
}

class ServiceProbeException implements Exception {
  const ServiceProbeException(this.kind, this.message);

  final ServiceProbeFailureKind kind;
  final String message;

  @override
  String toString() => message;
}
