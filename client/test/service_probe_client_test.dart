import 'dart:convert';
import 'dart:io';

import 'package:easy_calendar/data/service_probe_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('probes sync health, capabilities, and bearer authentication', () async {
    final requestedPaths = <String>[];
    final client = ServiceProbeClient(
      client: MockClient((request) async {
        requestedPaths.add(request.url.path);
        return switch (request.url.path) {
          '/v1/health' => http.Response(jsonEncode(_health()), 200),
          '/v1/capabilities' => http.Response(
            jsonEncode(_capabilities(sync: true, authRequired: true)),
            200,
          ),
          '/v1/auth-check' => http.Response(
            '{}',
            request.headers['Authorization'] == 'Bearer sync-token' ? 200 : 401,
          ),
          _ => http.Response('{}', 404),
        };
      }),
    );

    final result = await client.probe(
      serverUrl: Uri.parse('https://sync.example.com/base'),
      kind: ServiceKind.sync,
      token: 'sync-token',
    );

    expect(requestedPaths, [
      '/v1/health',
      '/v1/capabilities',
      '/v1/auth-check',
    ]);
    expect(result.serviceVersion, '0.1.0');
    expect(result.schemaVersion, 3);
    expect(result.capabilities.supports('sync'), isTrue);
  });

  test('allows an unauthenticated local feature service', () async {
    late http.Request authRequest;
    final client = ServiceProbeClient(
      client: MockClient((request) async {
        if (request.url.path == '/v1/health') {
          return http.Response(jsonEncode(_health(schemaVersion: 1)), 200);
        }
        if (request.url.path == '/v1/capabilities') {
          return http.Response(
            jsonEncode(_capabilities(feature: true, authRequired: false)),
            200,
          );
        }
        authRequest = request;
        return http.Response('{}', 200);
      }),
    );

    final result = await client.probe(
      serverUrl: Uri.parse('http://localhost:8000'),
      kind: ServiceKind.feature,
    );

    expect(authRequest.headers, isNot(contains('Authorization')));
    expect(result.capabilities.supports('ics_transfer'), isTrue);
  });

  test(
    'reports missing and rejected tokens as authentication errors',
    () async {
      final noTokenClient = ServiceProbeClient(
        client: MockClient(_successfulDiscovery),
      );
      await _expectFailure(
        noTokenClient.probe(
          serverUrl: Uri.parse('https://sync.example.com'),
          kind: ServiceKind.sync,
        ),
        ServiceProbeFailureKind.unauthorized,
      );

      final rejectedClient = ServiceProbeClient(
        client: MockClient((request) async {
          final discovered = await _successfulDiscovery(request);
          return request.url.path == '/v1/auth-check'
              ? http.Response('{}', 401)
              : discovered;
        }),
      );
      await _expectFailure(
        rejectedClient.probe(
          serverUrl: Uri.parse('https://sync.example.com'),
          kind: ServiceKind.sync,
          token: 'wrong-token',
        ),
        ServiceProbeFailureKind.unauthorized,
      );
    },
  );

  test(
    'distinguishes incompatible versions and missing capabilities',
    () async {
      final oldClient = ServiceProbeClient(
        client: MockClient((request) async {
          if (request.url.path == '/v1/health') {
            return http.Response(jsonEncode(_health()), 200);
          }
          return http.Response(
            jsonEncode({..._capabilities(sync: true), 'api_version': 'v2'}),
            200,
          );
        }),
      );
      await _expectFailure(
        oldClient.probe(
          serverUrl: Uri.parse('https://sync.example.com'),
          kind: ServiceKind.sync,
          token: 'token',
        ),
        ServiceProbeFailureKind.incompatibleVersion,
      );

      final wrongServiceClient = ServiceProbeClient(
        client: MockClient((request) async {
          if (request.url.path == '/v1/health') {
            return http.Response(jsonEncode(_health()), 200);
          }
          return http.Response(jsonEncode(_capabilities(feature: true)), 200);
        }),
      );
      await _expectFailure(
        wrongServiceClient.probe(
          serverUrl: Uri.parse('https://core.example.com'),
          kind: ServiceKind.sync,
          token: 'token',
        ),
        ServiceProbeFailureKind.missingCapability,
      );
    },
  );

  test('distinguishes DNS, TLS, timeout, and server failures', () async {
    await _expectFailure(
      ServiceProbeClient(
        client: MockClient(
          (_) async => throw const SocketException('Failed host lookup'),
        ),
      ).probe(
        serverUrl: Uri.parse('https://missing.example.com'),
        kind: ServiceKind.sync,
      ),
      ServiceProbeFailureKind.dns,
    );
    await _expectFailure(
      ServiceProbeClient(
        client: MockClient(
          (_) async => throw const HandshakeException('certificate rejected'),
        ),
      ).probe(
        serverUrl: Uri.parse('https://tls.example.com'),
        kind: ServiceKind.sync,
      ),
      ServiceProbeFailureKind.tls,
    );
    await _expectFailure(
      ServiceProbeClient(
        requestTimeout: const Duration(milliseconds: 1),
        client: MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return http.Response('{}', 200);
        }),
      ).probe(
        serverUrl: Uri.parse('https://slow.example.com'),
        kind: ServiceKind.sync,
      ),
      ServiceProbeFailureKind.timeout,
    );
    await _expectFailure(
      ServiceProbeClient(
        client: MockClient((_) async => http.Response('{}', 503)),
      ).probe(
        serverUrl: Uri.parse('https://offline.example.com'),
        kind: ServiceKind.sync,
      ),
      ServiceProbeFailureKind.server,
    );
  });
}

Future<http.Response> _successfulDiscovery(http.Request request) async =>
    switch (request.url.path) {
      '/v1/health' => http.Response(jsonEncode(_health()), 200),
      '/v1/capabilities' => http.Response(
        jsonEncode(_capabilities(sync: true, authRequired: true)),
        200,
      ),
      '/v1/auth-check' => http.Response('{}', 200),
      _ => http.Response('{}', 404),
    };

Map<String, Object?> _health({int schemaVersion = 3}) => {
  'status': 'ok',
  'service': 'easycalendar',
  'version': '0.1.0',
  'schema_version': schemaVersion,
};

Map<String, Object?> _capabilities({
  bool sync = false,
  bool feature = false,
  bool authRequired = false,
}) => {
  'api_version': 'v1',
  'features': {
    'sync': sync,
    'ics_subscriptions': feature,
    'ics_transfer': feature,
  },
  'configured': {'sync': sync},
  'authentication': {'required': authRequired, 'scheme': 'bearer'},
};

Future<void> _expectFailure(
  Future<ServiceProbeResult> future,
  ServiceProbeFailureKind kind,
) async {
  await expectLater(
    future,
    throwsA(
      isA<ServiceProbeException>().having((error) => error.kind, 'kind', kind),
    ),
  );
}
