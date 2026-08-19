import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'ai_http_client.dart';
import 'ai_provider.dart';

enum AiProviderProbeFailureKind {
  invalidUrl,
  dns,
  tls,
  timeout,
  unauthorized,
  server,
  invalidResponse,
  network,
}

class AiProviderProbeException implements Exception {
  const AiProviderProbeException(this.kind, this.message);

  final AiProviderProbeFailureKind kind;
  final String message;

  @override
  String toString() => message;
}

class AiProviderConnectionTester {
  AiProviderConnectionTester({this.client});

  final http.Client? client;

  Future<void> test(AiProviderConfig config, {String? apiKey}) async {
    await _request(config, apiKey: apiKey);
  }

  Future<List<String>> discoverModels(
    AiProviderConfig config, {
    String? apiKey,
  }) async {
    final body = await _request(config, apiKey: apiKey);
    final rawModels = config.kind == AiProviderKind.ollama
        ? body['models']
        : body['data'];
    if (rawModels is! List) {
      throw const AiProviderProbeException(
        AiProviderProbeFailureKind.invalidResponse,
        'Provider 的模型列表结构无效。',
      );
    }
    final models = <String>{};
    for (final entry in rawModels.whereType<Map>()) {
      final value = config.kind == AiProviderKind.ollama
          ? entry['name']
          : entry['id'];
      if (value is String && value.trim().isNotEmpty) {
        models.add(value.trim());
      }
    }
    if (models.isEmpty) {
      throw const AiProviderProbeException(
        AiProviderProbeFailureKind.invalidResponse,
        'Provider 没有返回可用模型，请手动填写模型名称。',
      );
    }
    return models.toList(growable: false)..sort();
  }

  Future<Map<String, dynamic>> _request(
    AiProviderConfig config, {
    String? apiKey,
  }) async {
    final base = Uri.tryParse(config.baseUrl.trim());
    if (base == null ||
        !base.hasAuthority ||
        base.userInfo.isNotEmpty ||
        !{'http', 'https'}.contains(base.scheme)) {
      throw const AiProviderProbeException(
        AiProviderProbeFailureKind.invalidUrl,
        '请输入有效的 HTTP(S) Provider 地址。',
      );
    }
    final endpoint = config.kind == AiProviderKind.ollama
        ? resolveAiProviderEndpoint(base, 'api/tags')
        : resolveAiProviderEndpoint(base, 'models');
    final headers = <String, String>{'Accept': 'application/json'};
    if (config.kind == AiProviderKind.openaiCompatible &&
        (apiKey ?? '').trim().isNotEmpty) {
      headers['Authorization'] = 'Bearer ${apiKey!.trim()}';
    }
    late http.Response response;
    final requestClient = client ?? createAiHttpClient(config.proxyUrl);
    try {
      response = await requestClient
          .get(endpoint, headers: headers)
          .timeout(Duration(seconds: config.requestTimeoutSeconds));
    } on TimeoutException {
      throw const AiProviderProbeException(
        AiProviderProbeFailureKind.timeout,
        'Provider 连接超时，请检查地址和网络。',
      );
    } on HandshakeException {
      throw const AiProviderProbeException(
        AiProviderProbeFailureKind.tls,
        'Provider TLS 证书或握手失败。',
      );
    } on SocketException catch (error) {
      final dns = _looksLikeDnsFailure(error.message);
      throw AiProviderProbeException(
        dns
            ? AiProviderProbeFailureKind.dns
            : AiProviderProbeFailureKind.network,
        dns ? '无法解析 Provider 域名，请检查地址或 DNS。' : '无法连接 Provider。',
      );
    } on http.ClientException catch (error) {
      final message = error.message.toLowerCase();
      final dns = _looksLikeDnsFailure(message);
      final tls =
          message.contains('certificate') ||
          message.contains('handshake') ||
          message.contains('tls');
      throw AiProviderProbeException(
        dns
            ? AiProviderProbeFailureKind.dns
            : tls
            ? AiProviderProbeFailureKind.tls
            : AiProviderProbeFailureKind.network,
        dns
            ? '无法解析 Provider 域名，请检查地址或 DNS。'
            : tls
            ? 'Provider TLS 证书或握手失败。'
            : '无法连接 Provider。',
      );
    } finally {
      if (client == null) requestClient.close();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const AiProviderProbeException(
          AiProviderProbeFailureKind.unauthorized,
          'Provider 拒绝鉴权，请检查 API Key。',
        );
      }
      if (response.statusCode >= 500) {
        throw AiProviderProbeException(
          AiProviderProbeFailureKind.server,
          'Provider 暂时不可用（HTTP ${response.statusCode}）。',
        );
      }
      throw AiProviderProbeException(
        AiProviderProbeFailureKind.invalidResponse,
        'Provider 返回意外状态（HTTP ${response.statusCode}）。',
      );
    }
    Object? body;
    try {
      body = jsonDecode(response.body);
    } on FormatException {
      throw const AiProviderProbeException(
        AiProviderProbeFailureKind.invalidResponse,
        'Provider 返回的内容不是有效 JSON。',
      );
    }
    if (body is! Map<String, dynamic>) {
      throw const AiProviderProbeException(
        AiProviderProbeFailureKind.invalidResponse,
        'Provider 返回的 JSON 结构无效。',
      );
    }
    return body;
  }

  static bool _looksLikeDnsFailure(String message) {
    final lower = message.toLowerCase();
    return lower.contains('failed host lookup') ||
        lower.contains('name or service not known') ||
        lower.contains('nodename nor servname');
  }

  void close() => client?.close();
}
