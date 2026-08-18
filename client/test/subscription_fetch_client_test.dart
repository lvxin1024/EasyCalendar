import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:easy_calendar/data/subscription_fetch_client.dart';
import 'package:easy_calendar/domain/subscription.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const subscription = CalendarSubscription(
    id: 'sub_1',
    collectionId: 'col_1',
    title: 'Team',
    url: 'https://example.com/team.ics',
    enabled: true,
    version: 2,
    etag: '"v1"',
    lastModified: 'Tue, 18 Aug 2026 00:00:00 GMT',
    sourceHash: 'old-hash',
  );

  test('sends conditional headers and hashes successful content', () async {
    late http.Request request;
    final client = SubscriptionFetchClient(
      client: MockClient((value) async {
        request = value;
        return http.Response(
          'BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n',
          200,
          headers: {
            'etag': '"v2"',
            'last-modified': 'Wed, 19 Aug 2026 00:00:00 GMT',
          },
        );
      }),
    );

    final response = await client.fetch(subscription);

    expect(request.headers['If-None-Match'], '"v1"');
    expect(
      request.headers['If-Modified-Since'],
      'Tue, 18 Aug 2026 00:00:00 GMT',
    );
    expect(response.etag, '"v2"');
    expect(
      response.sourceHash,
      sha256.convert(utf8.encode(response.content)).toString(),
    );
    client.close();
  });

  test('preserves validators when the source returns 304', () async {
    final client = SubscriptionFetchClient(
      client: MockClient((_) async => http.Response('', 304)),
    );

    final response = await client.fetch(subscription);

    expect(response.notModified, isTrue);
    expect(response.etag, subscription.etag);
    expect(response.lastModified, subscription.lastModified);
    expect(response.sourceHash, subscription.sourceHash);
    client.close();
  });

  test('reports non-success HTTP status', () async {
    final client = SubscriptionFetchClient(
      client: MockClient((_) async => http.Response('unavailable', 503)),
    );

    await expectLater(
      client.fetch(subscription),
      throwsA(
        isA<SubscriptionFetchException>().having(
          (error) => error.statusCode,
          'statusCode',
          503,
        ),
      ),
    );
    client.close();
  });
}
