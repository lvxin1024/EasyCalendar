import 'dart:convert';

import 'package:easy_calendar/sync/http_sync_transport.dart';
import 'package:easy_calendar/sync/sync_models.dart';
import 'package:easy_calendar/sync/sync_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'push sends the authenticated change envelope and parses rejections',
    () async {
      late http.Request captured;
      final transport = HttpSyncTransport(
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'accepted': ['change_01'],
              'rejected': [
                {
                  'change_id': 'change_02',
                  'code': 'constraint_violation',
                  'message': 'invalid',
                },
              ],
              'conflicts': [
                {
                  'entity_type': 'item',
                  'entity_id': 'item_01',
                  'resolution': 'stored_won',
                  'winner': {
                    ..._pendingChange().toJson(),
                    'change_id': 'change_winner',
                  },
                  'loser': {
                    ..._pendingChange().toJson(),
                    'change_id': 'change_02',
                  },
                },
              ],
              'server_cursor': 'cur_1',
            }),
            200,
          );
        }),
      );

      final result = await transport.push(
        serverUrl: Uri.parse('https://sync.example.com/base'),
        token: 'secret-token',
        deviceId: 'test-device',
        idempotencyKey: 'push_01',
        changes: [_pendingChange()],
      );

      expect(captured.url.toString(), 'https://sync.example.com/v1/sync/push');
      expect(captured.headers['Authorization'], 'Bearer secret-token');
      expect(captured.headers['Idempotency-Key'], 'push_01');
      expect(jsonDecode(captured.body), {
        'device_id': 'test-device',
        'changes': [_pendingChange().toJson()],
      });
      expect(result.accepted, ['change_01']);
      expect(result.rejected.single.code, 'constraint_violation');
      expect(result.conflicts.single.winner.changeId, 'change_winner');
    },
  );

  test('401 responses become authentication failures', () async {
    final transport = HttpSyncTransport(
      client: MockClient((_) async => http.Response('{}', 401)),
    );

    expect(
      () => transport.pull(
        serverUrl: Uri.parse('https://sync.example.com'),
        token: 'bad-token',
      ),
      throwsA(isA<SyncAuthenticationException>()),
    );
  });
}

PendingSyncChange _pendingChange() => PendingSyncChange(
  changeId: 'change_01',
  deviceId: 'test-device',
  entityType: 'item',
  entityId: 'item_01',
  operation: 'create',
  version: 1,
  updatedAt: DateTime.utc(2026, 8, 11, 8),
  payload: const {
    'id': 'item_01',
    'collection_id': 'collection_local',
    'type': 'task',
    'updated_at': '2026-08-11T08:00:00.000Z',
    'version': 1,
  },
  retryCount: 0,
);
