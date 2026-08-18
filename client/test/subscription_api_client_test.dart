import 'package:easy_calendar/data/subscription_api_client.dart';
import 'package:easy_calendar/domain/subscription.dart';
import 'package:easy_calendar/sync/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('lists subscriptions with bearer authentication', () async {
    late http.Request request;
    final client = MockClient((value) async {
      request = value;
      return http.Response(
        '{"data":[{"id":"sub_1","collection_id":"col_1",'
        '"title":"course","url":"https://example.com/a.ics",'
        '"enabled":true,"version":2,"metadata":'
        '{"refresh_interval_minutes":180}}]}',
        200,
      );
    });
    final api = SubscriptionApiClient(
      tokenStore: const _MemoryTokenStore('token'),
      client: client,
    );

    final subscriptions = await api.list(Uri.parse('https://sync.example.com'));

    expect(subscriptions.single.title, 'course');
    expect(subscriptions.single.refreshIntervalMinutes, 180);
    expect(request.headers['Authorization'], 'Bearer token');
  });

  test('creates subscription with refresh interval metadata', () async {
    late http.Request request;
    final api = SubscriptionApiClient(
      tokenStore: const _MemoryTokenStore('token'),
      client: MockClient((value) async {
        request = value;
        return http.Response(
          '{"id":"sub_1","collection_id":"col_1",'
          '"title":"course","url":"https://example.com/a.ics",'
          '"enabled":true,"version":1}',
          201,
        );
      }),
    );

    await api.create(
      Uri.parse('https://sync.example.com'),
      title: 'course',
      url: 'https://example.com/a.ics',
      refreshIntervalMinutes: 180,
    );

    expect(request.headers['Authorization'], 'Bearer token');
    expect(request.headers['Idempotency-Key'], startsWith('subscription_'));
    expect(request.body, contains('"refresh_interval_minutes":180'));
  });

  test('refresh accepts a refresh report response', () async {
    final api = SubscriptionApiClient(
      tokenStore: const _MemoryTokenStore('token'),
      client: MockClient(
        (_) async => http.Response(
          '{"status":"success","subscription_id":"sub_1"}',
          200,
        ),
      ),
    );

    await api.refresh(
      Uri.parse('https://sync.example.com'),
      const CalendarSubscription(
        id: 'sub_1',
        collectionId: 'col_1',
        title: 'course',
        url: 'https://example.com/a.ics',
        enabled: true,
        version: 1,
      ),
    );
  });

  test('omits authorization when the feature service has no token', () async {
    late http.Request request;
    final api = SubscriptionApiClient(
      tokenStore: const _MemoryTokenStore(null),
      client: MockClient((value) async {
        request = value;
        return http.Response('{"data":[]}', 200);
      }),
    );

    await api.list(Uri.parse('http://localhost:8000'));

    expect(request.headers, isNot(contains('Authorization')));
  });
}

class _MemoryTokenStore implements SyncTokenStore {
  const _MemoryTokenStore(this.value);

  final String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String token) async {}

  @override
  Future<void> clear() async {}
}
