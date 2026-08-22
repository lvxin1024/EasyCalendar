import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../domain/subscription.dart';
import '../sync/token_store.dart';

class SubscriptionApiClient {
  SubscriptionApiClient({
    required this.tokenStore,
    http.Client? client,
    Uuid? uuid,
  }) : _client = client ?? http.Client(),
       _uuid = uuid ?? const Uuid();

  final SyncTokenStore tokenStore;
  final http.Client _client;
  final Uuid _uuid;

  Future<List<CalendarSubscription>> list(Uri base) async {
    final response = await _send(
      (headers) =>
          _client.get(_endpoint(base, '/v1/subscriptions'), headers: headers),
    );
    final body = _object(response.body);
    return _list(
      body,
    ).map(CalendarSubscription.fromJson).toList(growable: false);
  }

  Future<CalendarSubscription> create(
    Uri base, {
    required String title,
    required String url,
    required int refreshIntervalMinutes,
    List<String> tags = const [],
  }) async {
    final response = await _send(
      (headers) => _client.post(
        _endpoint(base, '/v1/subscriptions'),
        headers: headers,
        body: jsonEncode({
          'type': 'ics',
          'title': title,
          'url': url,
          'enabled': true,
          'metadata': {
            'refresh_interval_minutes': refreshIntervalMinutes,
            'tags': tags,
          },
        }),
      ),
      idempotencyKey: 'subscription_${_uuid.v4()}',
    );
    return CalendarSubscription.fromJson(_object(response.body));
  }

  Future<CalendarSubscription> update(
    Uri base,
    CalendarSubscription current, {
    required Map<String, Object?> patch,
  }) async {
    final response = await _send(
      (headers) => _client.patch(
        _endpoint(base, '/v1/subscriptions/${current.id}'),
        headers: headers,
        body: jsonEncode({'expected_version': current.version, 'patch': patch}),
      ),
    );
    return CalendarSubscription.fromJson(_object(response.body));
  }

  Future<void> refresh(Uri base, CalendarSubscription current) async {
    await _send(
      (headers) => _client.post(
        _endpoint(base, '/v1/subscriptions/${current.id}/refresh'),
        headers: headers,
      ),
      idempotencyKey: 'refresh_${_uuid.v4()}',
    );
  }

  Future<void> delete(Uri base, CalendarSubscription current) async {
    await _send(
      (headers) => _client.delete(
        _endpoint(
          base,
          '/v1/subscriptions/${current.id}',
        ).replace(queryParameters: {'expected_version': '${current.version}'}),
        headers: headers,
      ),
    );
  }

  Future<List<SubscriptionFetchLog>> logs(
    Uri base,
    CalendarSubscription current,
  ) async {
    final response = await _send(
      (headers) => _client.get(
        _endpoint(base, '/v1/subscriptions/${current.id}/fetch-logs'),
        headers: headers,
      ),
    );
    return _list(
      _object(response.body),
    ).map(SubscriptionFetchLog.fromJson).toList(growable: false);
  }

  Future<http.Response> _send(
    Future<http.Response> Function(Map<String, String> headers) request, {
    String? idempotencyKey,
  }) async {
    final token = await tokenStore.read();
    late http.Response response;
    try {
      response = await request(
        _headers(token, idempotencyKey: idempotencyKey),
      ).timeout(const Duration(seconds: 30));
    } catch (error) {
      throw SubscriptionApiException('订阅请求失败：$error');
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response;
    }
    throw SubscriptionApiException(
      _error(response.body) ?? '订阅服务返回 HTTP ${response.statusCode}',
    );
  }

  static Map<String, String> _headers(
    String? token, {
    String? idempotencyKey,
  }) => {
    if (token?.isNotEmpty == true) 'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
    ...?idempotencyKey == null ? null : {'Idempotency-Key': idempotencyKey},
  };

  Uri _endpoint(Uri base, String path) => base.resolve(path);

  static Map<String, Object?> _object(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map<Object?, Object?>) {
      throw const SubscriptionApiException('订阅响应必须是 JSON object。');
    }
    return decoded.cast<String, Object?>();
  }

  static List<Map<String, Object?>> _list(Map<String, Object?> body) {
    final values = body['data'] ?? body['subscriptions'] ?? const [];
    if (values is! List) return const [];
    return values
        .whereType<Map<Object?, Object?>>()
        .map((value) => value.cast<String, Object?>())
        .toList(growable: false);
  }

  static String? _error(String body) {
    try {
      final value = _object(body)['error'];
      if (value is Map<Object?, Object?>) return value['message'] as String?;
      return value as String?;
    } catch (_) {
      return null;
    }
  }

  void close() => _client.close();
}

class SubscriptionApiException implements Exception {
  const SubscriptionApiException(this.message);

  final String message;

  @override
  String toString() => message;
}
