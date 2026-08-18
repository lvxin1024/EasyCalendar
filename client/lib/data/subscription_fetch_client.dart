import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../domain/subscription.dart';

class SubscriptionFetchResponse {
  const SubscriptionFetchResponse({
    required this.statusCode,
    required this.content,
    this.etag,
    this.lastModified,
    this.sourceHash,
  });

  final int statusCode;
  final String content;
  final String? etag;
  final String? lastModified;
  final String? sourceHash;

  bool get notModified => statusCode == 304;
}

class SubscriptionFetchClient {
  SubscriptionFetchClient({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  Future<SubscriptionFetchResponse> fetch(
    CalendarSubscription subscription,
  ) async {
    final uri = Uri.parse(subscription.url);
    late http.Response response;
    try {
      response = await _client
          .get(
            uri,
            headers: {
              'Accept': 'text/calendar, text/plain;q=0.9, */*;q=0.1',
              if (subscription.etag?.isNotEmpty == true)
                'If-None-Match': subscription.etag!,
              if (subscription.lastModified?.isNotEmpty == true)
                'If-Modified-Since': subscription.lastModified!,
            },
          )
          .timeout(const Duration(seconds: 30));
    } catch (error) {
      throw SubscriptionFetchException('订阅抓取失败：$error');
    }
    if (response.statusCode == 304) {
      return SubscriptionFetchResponse(
        statusCode: 304,
        content: '',
        etag: response.headers['etag'] ?? subscription.etag,
        lastModified:
            response.headers['last-modified'] ?? subscription.lastModified,
        sourceHash: subscription.sourceHash,
      );
    }
    if (response.statusCode != 200) {
      throw SubscriptionFetchException(
        '订阅源返回 HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    const maximumBytes = 10 * 1024 * 1024;
    if (response.bodyBytes.length > maximumBytes) {
      throw const SubscriptionFetchException('订阅文件超过 10 MB 限制。');
    }
    final content = utf8.decode(response.bodyBytes, allowMalformed: true);
    return SubscriptionFetchResponse(
      statusCode: 200,
      content: content,
      etag: response.headers['etag'],
      lastModified: response.headers['last-modified'],
      sourceHash: sha256.convert(response.bodyBytes).toString(),
    );
  }

  void close() => _client.close();
}

class SubscriptionFetchException implements Exception {
  const SubscriptionFetchException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}
