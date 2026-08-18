import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

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
  AiProviderConnectionTester({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  Future<void> test(AiProviderConfig config, {String? apiKey}) async {
    final base = Uri.tryParse(config.baseUrl.trim());
    if (base == null ||
        !base.hasAuthority ||
        !{'http', 'https'}.contains(base.scheme)) {
      throw const AiProviderProbeException(
        AiProviderProbeFailureKind.invalidUrl,
        '请输入有效的 HTTP(S) Provider 地址。',
      );
    }
    final endpoint = config.kind == AiProviderKind.ollama
        ? base.resolve('/api/tags')
        : base.resolve('/models');
    final headers = <String, String>{'Accept': 'application/json'};
    if (config.kind == AiProviderKind.openaiCompatible &&
        (apiKey ?? '').trim().isNotEmpty) {
      headers['Authorization'] = 'Bearer ${apiKey!.trim()}';
    }
    late http.Response response;
    try {
      response = await _client
          .get(endpoint, headers: headers)
          .timeout(const Duration(seconds: 10));
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
  }

  static bool _looksLikeDnsFailure(String message) {
    final lower = message.toLowerCase();
    return lower.contains('failed host lookup') ||
        lower.contains('name or service not known') ||
        lower.contains('nodename nor servname');
  }

  void close() => _client.close();
}
