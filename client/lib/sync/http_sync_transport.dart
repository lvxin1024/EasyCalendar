import 'dart:convert';

import 'package:http/http.dart' as http;

import 'sync_models.dart';
import 'sync_transport.dart';

class HttpSyncTransport implements SyncTransport {
  HttpSyncTransport({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  @override
  Future<PushSyncResult> push({
    required Uri serverUrl,
    required String token,
    required String deviceId,
    required String idempotencyKey,
    required List<PendingSyncChange> changes,
  }) async {
    final response = await _send(
      () => _client.post(
        serverUrl.resolve('/v1/sync/push'),
        headers: _headers(token, idempotencyKey: idempotencyKey),
        body: jsonEncode({
          'device_id': deviceId,
          'changes': changes.map((change) => change.toJson()).toList(),
        }),
      ),
    );
    final body = _decodeObject(response.body);
    return PushSyncResult(
      accepted: (body['accepted'] as List<Object?>).cast<String>(),
      rejected: (body['rejected'] as List<Object?>)
          .map((value) {
            final rejection = (value as Map<Object?, Object?>)
                .cast<String, Object?>();
            return SyncRejection(
              changeId: rejection['change_id'] as String,
              code: rejection['code'] as String,
              message: rejection['message'] as String,
            );
          })
          .toList(growable: false),
      conflicts: (body['conflicts'] as List<Object?>)
          .map(
            (value) => SyncConflictSummary.fromJson(
              (value as Map<Object?, Object?>).cast<String, Object?>(),
            ),
          )
          .toList(growable: false),
    );
  }

  @override
  Future<PullSyncPage> pull({
    required Uri serverUrl,
    required String token,
    String? cursor,
    int limit = 200,
  }) async {
    final query = <String, String>{'limit': '$limit'};
    if (cursor != null) query['cursor'] = cursor;
    final endpoint = serverUrl
        .resolve('/v1/sync/pull')
        .replace(queryParameters: query);
    final response = await _send(
      () => _client.get(endpoint, headers: _headers(token)),
    );
    final body = _decodeObject(response.body);
    return PullSyncPage(
      cursor: body['cursor'] as String,
      hasMore: body['has_more'] as bool,
      changes: (body['changes'] as List<Object?>)
          .map(
            (value) => RemoteSyncChange.fromJson(
              (value as Map<Object?, Object?>).cast<String, Object?>(),
            ),
          )
          .toList(growable: false),
    );
  }

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    late http.Response response;
    try {
      response = await request().timeout(const Duration(seconds: 30));
    } catch (error) {
      throw SyncTransportException('网络请求失败：$error');
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response;
    }
    if (response.statusCode == 401) {
      throw const SyncAuthenticationException();
    }
    final message =
        _errorMessage(response.body) ?? '同步服务返回 ${response.statusCode}';
    final permanent =
        response.statusCode >= 400 &&
        response.statusCode < 500 &&
        response.statusCode != 408 &&
        response.statusCode != 429;
    throw SyncTransportException(message, permanent: permanent);
  }

  static Map<String, String> _headers(String token, {String? idempotencyKey}) {
    final headers = {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
    if (idempotencyKey != null) {
      headers['Idempotency-Key'] = idempotencyKey;
    }
    return headers;
  }

  static Map<String, Object?> _decodeObject(String value) {
    final decoded = jsonDecode(value);
    if (decoded is! Map<Object?, Object?>) {
      throw const FormatException('同步服务响应必须是 JSON object');
    }
    return decoded.cast<String, Object?>();
  }

  static String? _errorMessage(String value) {
    try {
      final body = _decodeObject(value);
      final error = body['error'];
      return error is Map<Object?, Object?>
          ? error['message'] as String?
          : null;
    } catch (_) {
      return null;
    }
  }
}
