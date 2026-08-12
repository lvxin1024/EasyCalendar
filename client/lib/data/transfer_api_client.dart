import 'dart:convert';

import 'package:http/http.dart' as http;

class TransferResult {
  const TransferResult({
    required this.accepted,
    required this.committed,
    required this.format,
    required this.created,
    required this.skipped,
    required this.conflicts,
    required this.issues,
  });

  final bool accepted;
  final bool committed;
  final String format;
  final Map<String, int> created;
  final Map<String, int> skipped;
  final Map<String, int> conflicts;
  final List<TransferIssue> issues;
}

class TransferIssue {
  const TransferIssue({
    required this.resourceType,
    required this.index,
    required this.message,
    this.resourceId,
    this.code = 'invalid',
  });

  final String resourceType;
  final int index;
  final String message;
  final String? resourceId;
  final String code;
}

class TransferApiClient {
  TransferApiClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<String> exportJson({
    required Uri serverUrl,
    required String token,
    String? collectionId,
  }) async {
    final queryParams = <String, String>{
      'format': 'json',
      'scope': collectionId != null ? 'collection' : 'all',
    };
    if (collectionId != null) queryParams['collection_id'] = collectionId;
    return _fetchExport(serverUrl, token, queryParams);
  }

  Future<String> exportIcs({
    required Uri serverUrl,
    required String token,
    String? collectionId,
  }) async {
    final queryParams = <String, String>{
      'format': 'ics',
      'scope': collectionId != null ? 'collection' : 'all',
    };
    if (collectionId != null) queryParams['collection_id'] = collectionId;
    return _fetchExport(serverUrl, token, queryParams);
  }

  Future<String> _fetchExport(
    Uri serverUrl,
    String token,
    Map<String, String> queryParams,
  ) async {
    final endpoint = serverUrl
        .resolve('/v1/export')
        .replace(queryParameters: queryParams);
    final response = await _send(
      () => _client.get(endpoint, headers: _headers(token)),
    );
    return response.body;
  }

  Future<TransferResult> importContent({
    required Uri serverUrl,
    required String token,
    required String idempotencyKey,
    required String format,
    required String mode,
    required String strategy,
    required String content,
    String? collectionId,
  }) async {
    final body = <String, dynamic>{
      'format': format,
      'mode': mode,
      'strategy': strategy,
      'content': content,
    };
    if (collectionId != null) body['collection_id'] = collectionId;
    final response = await _send(
      () => _client.post(
        serverUrl.resolve('/v1/import'),
        headers: _headers(token, idempotencyKey: idempotencyKey),
        body: jsonEncode(body),
      ),
    );
    final decoded = _decodeObject(response.body);
    return TransferResult(
      accepted: decoded['accepted'] as bool,
      committed: decoded['committed'] as bool,
      format: decoded['format'] as String,
      created: _decodeCounts(decoded['created']),
      skipped: _decodeCounts(decoded['skipped']),
      conflicts: _decodeCounts(decoded['conflicts']),
      issues: (decoded['issues'] as List<dynamic>)
          .map((value) {
            final issue = (value as Map).cast<String, dynamic>();
            return TransferIssue(
              resourceType: issue['resource_type'] as String,
              index: issue['index'] as int,
              message: issue['message'] as String,
              resourceId: issue['id'] as String?,
              code: issue['code'] as String? ?? 'invalid',
            );
          })
          .toList(growable: false),
    );
  }

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    late http.Response response;
    try {
      response = await request().timeout(const Duration(seconds: 60));
    } catch (error) {
      throw TransferApiException('网络请求失败：$error');
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response;
    }
    if (response.statusCode == 401) {
      throw const TransferApiException('访问令牌无效或已失效。', permanent: true);
    }
    final message = _errorMessage(response.body) ??
        '传输服务返回 ${response.statusCode}';
    throw TransferApiException(message, permanent: response.statusCode >= 400);
  }

  static Map<String, int> _decodeCounts(dynamic value) {
    if (value is! Map) return {};
    return value.map<String, int>(
      (key, count) => MapEntry('$key', count is int ? count : 0),
    );
  }

  static Map<String, String> _headers(
    String token, {
    String? idempotencyKey,
  }) {
    final headers = {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
    if (idempotencyKey != null) {
      headers['Idempotency-Key'] = idempotencyKey;
    }
    return headers;
  }

  static Map<String, dynamic> _decodeObject(String value) {
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('传输服务响应必须是 JSON object');
    }
    return decoded;
  }

  static String? _errorMessage(String value) {
    try {
      final body = jsonDecode(value);
      if (body is Map) {
        final detail = body['detail'];
        return detail is String ? detail : null;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  void close() => _client.close();
}

class TransferApiException implements Exception {
  const TransferApiException(this.message, {this.permanent = false});

  final String message;
  final bool permanent;

  @override
  String toString() => message;
}
