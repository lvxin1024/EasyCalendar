import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_http_client.dart';
import 'ai_key_store.dart';
import 'ai_provider.dart';
import 'assistant_models.dart';

class AiAssistantClient {
  AiAssistantClient({this.client, AiApiKeyStore? keyStore})
    : _keyStore = keyStore ?? SecureAiApiKeyStore();

  final http.Client? client;
  final AiApiKeyStore _keyStore;

  Future<AiExtractionResult> extract({
    required AiProviderConfig provider,
    required String text,
    required String timezone,
  }) async {
    final key = await _keyStore.read(provider.id);
    if (provider.kind == AiProviderKind.openaiCompatible &&
        (key ?? '').trim().isEmpty) {
      throw const AiAssistantException('此 Provider 尚未配置 API key');
    }
    final base = Uri.tryParse(provider.baseUrl.trim());
    if (base == null ||
        !base.hasAuthority ||
        !{'http', 'https'}.contains(base.scheme)) {
      throw const AiAssistantException('Provider 地址无效');
    }
    final prompt =
        'Return JSON only: {"candidates":[...],"warnings":[...]}. '
        'Every candidate needs temp_id, type (event|task|note), title, confidence, timezone. '
        'Use ISO 8601 times and include source_text_span when possible. '
        'Timezone: $timezone. Input: $text';
    final endpoint = provider.kind == AiProviderKind.ollama
        ? base.resolve('/api/chat')
        : base.resolve('/chat/completions');
    final payload = provider.kind == AiProviderKind.ollama
        ? {
            ...provider.payloadRequestParameters,
            'model': provider.model,
            'stream': false,
            'format': 'json',
            'options': {
              'temperature': provider.temperature,
              if (provider.maxTokens != null) 'num_predict': provider.maxTokens,
            },
            'messages': [
              {'role': 'user', 'content': prompt},
            ],
          }
        : {
            ...provider.payloadRequestParameters,
            'model': provider.model,
            'temperature': provider.temperature,
            if (provider.maxTokens != null) 'max_tokens': provider.maxTokens,
            'response_format': {'type': 'json_object'},
            'messages': [
              {'role': 'user', 'content': prompt},
            ],
          };
    final headers = {
      'Content-Type': 'application/json',
      if (key != null) 'Authorization': 'Bearer ${key.trim()}',
    };
    final response = await _postWithRetry(
      endpoint,
      provider: provider,
      headers: headers,
      body: jsonEncode(payload),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AiAssistantException('Provider 返回 HTTP ${response.statusCode}');
    }
    if (response.bodyBytes.length > 2000000) {
      throw const AiAssistantException('Provider 响应过大');
    }
    try {
      final envelope = jsonDecode(response.body);
      final content = provider.kind == AiProviderKind.ollama
          ? (envelope as Map<String, dynamic>)['message']['content']
          : (envelope
                as Map<String, dynamic>)['choices'][0]['message']['content'];
      final decoded = jsonDecode(
        (content as String)
            .replaceFirst(RegExp(r'^```json\s*'), '')
            .replaceFirst(RegExp(r'```\s*$'), '')
            .trim(),
      );
      final decodedObject = decoded is Map<String, dynamic> ? decoded : null;
      final raw = decoded is List ? decoded : decodedObject?['candidates'];
      if (raw is! List) {
        throw const FormatException('candidates must be an array');
      }
      final candidates = <AiCandidate>[];
      final issues = <AiCandidateIssue>[];
      for (var index = 0; index < raw.length; index++) {
        try {
          candidates.add(
            AiCandidate.fromJson(Map<String, dynamic>.from(raw[index] as Map)),
          );
        } catch (error) {
          issues.add(AiCandidateIssue(index: index, message: '$error'));
        }
      }
      final rawWarnings = decodedObject?['warnings'];
      final warnings = rawWarnings is List
          ? rawWarnings.whereType<String>().toList(growable: false)
          : const <String>[];
      return AiExtractionResult(
        candidates: candidates,
        issues: issues,
        warnings: warnings,
      );
    } catch (error) {
      if (error is AiAssistantException) rethrow;
      throw AiAssistantException('Provider 输出无效：$error');
    }
  }

  Future<http.Response> _postWithRetry(
    Uri endpoint, {
    required AiProviderConfig provider,
    required Map<String, String> headers,
    required String body,
  }) async {
    final requestClient = client ?? createAiHttpClient(provider.proxyUrl);
    Object? lastError;
    try {
      for (var attempt = 0; attempt <= provider.retryCount; attempt++) {
        try {
          final response = await requestClient
              .post(endpoint, headers: headers, body: body)
              .timeout(Duration(seconds: provider.requestTimeoutSeconds));
          final retryable =
              response.statusCode == 408 ||
              response.statusCode == 429 ||
              response.statusCode >= 500;
          if (!retryable || attempt == provider.retryCount) return response;
        } catch (error) {
          lastError = error;
          if (attempt == provider.retryCount) break;
        }
        await Future<void>.delayed(
          Duration(milliseconds: 250 * (1 << attempt)),
        );
      }
    } finally {
      if (client == null) requestClient.close();
    }
    throw AiAssistantException('Provider 请求失败：$lastError');
  }

  void close() {
    client?.close();
  }
}

class AiAssistantException implements Exception {
  const AiAssistantException(this.message);

  final String message;

  @override
  String toString() => message;
}
