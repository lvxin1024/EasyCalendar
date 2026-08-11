import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_provider.dart';

class AiProviderConnectionTester {
  AiProviderConnectionTester({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  Future<void> test(AiProviderConfig config, {String? apiKey}) async {
    final base = Uri.tryParse(config.baseUrl.trim());
    if (base == null ||
        !base.hasAuthority ||
        !{'http', 'https'}.contains(base.scheme)) {
      throw const FormatException('请输入有效的 HTTP(S) Provider 地址');
    }
    final endpoint = config.kind == AiProviderKind.ollama
        ? base.resolve('/api/tags')
        : base.resolve('/models');
    final headers = <String, String>{'Accept': 'application/json'};
    if (config.kind == AiProviderKind.openaiCompatible &&
        (apiKey ?? '').trim().isNotEmpty) {
      headers['Authorization'] = 'Bearer ${apiKey!.trim()}';
    }
    final response = await _client
        .get(endpoint, headers: headers)
        .timeout(const Duration(seconds: 10));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Provider 返回 HTTP ${response.statusCode}');
    }
    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic>) {
      throw const FormatException('Provider 返回不是 JSON 对象');
    }
  }

  void close() => _client.close();
}
