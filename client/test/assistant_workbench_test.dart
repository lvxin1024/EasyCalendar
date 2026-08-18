import 'dart:convert';

import 'package:easy_calendar/ai/ai_assistant_client.dart';
import 'package:easy_calendar/ai/ai_key_store.dart';
import 'package:easy_calendar/ai/ai_provider.dart';
import 'package:easy_calendar/ai/assistant_models.dart';
import 'package:easy_calendar/domain/item.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('candidate workbench edits, splits, merges, and rejects in memory', () {
    final first = _candidate('one', '评审和复盘');
    final second = _candidate('two', '提交报告');
    final workbench = CandidateWorkbench([first, second]);

    workbench.split(0, [
      first.copyWith(title: '评审'),
      first.copyWith(title: '复盘'),
    ]);
    expect(workbench.candidates.map((value) => value.title), [
      '评审',
      '复盘',
      '提交报告',
    ]);

    final merged = workbench.merge(0, 1);
    expect(merged.title, '评审 / 复盘');
    expect(workbench.candidates, hasLength(2));
    expect(workbench.reject(1).tempId, 'two');
    expect(workbench.candidates, hasLength(1));
  });

  test('candidate becomes an ItemDraft only when explicitly requested', () {
    final candidate = _candidate('one', '评审');

    final draft = candidate.toDraft();

    expect(draft.title, '评审');
    expect(draft.type, ItemType.event);
    expect(draft.startAt, DateTime.parse('2026-08-12T09:00:00+08:00'));
  });

  test(
    'OpenAI client returns multiple candidates and keeps key out of body',
    () async {
      late http.Request captured;
      final client = AiAssistantClient(
        keyStore: _MemoryKeyStore({'cloud': 'top-secret'}),
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': jsonEncode({
                      'candidates': [
                        _candidateJson('one', '评审'),
                        _candidateJson('two', '提交报告'),
                      ],
                    }),
                  },
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      addTearDown(client.close);

      final result = await client.extract(
        provider: _provider,
        text: '明天评审，周五前提交报告',
        timezone: 'Asia/Shanghai',
      );

      expect(result.candidates.map((value) => value.title), ['评审', '提交报告']);
      expect(result.issues, isEmpty);
      expect(captured.headers['Authorization'], 'Bearer top-secret');
      expect(captured.body, isNot(contains('top-secret')));
    },
  );

  test(
    'OpenAI client applies request parameters and configured retries',
    () async {
      var requests = 0;
      late Map<String, dynamic> payload;
      final client = AiAssistantClient(
        keyStore: _MemoryKeyStore({'cloud': 'top-secret'}),
        client: MockClient((request) async {
          requests++;
          payload = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
          if (requests == 1) return http.Response('{}', 503);
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': jsonEncode({'candidates': <Object>[]}),
                  },
                },
              ],
            }),
            200,
          );
        }),
      );
      addTearDown(client.close);

      await client.extract(
        provider: _provider.copyWith(
          requestParameters: const {
            'temperature': 0.4,
            'max_tokens': 512,
            'retry_count': 1,
            'request_timeout_seconds': 10,
            'proxy_url': 'http://127.0.0.1:7890',
          },
        ),
        text: '安排事项',
        timezone: 'Asia/Shanghai',
      );

      expect(requests, 2);
      expect(payload['temperature'], 0.4);
      expect(payload['max_tokens'], 512);
      expect(payload, isNot(contains('retry_count')));
      expect(payload, isNot(contains('request_timeout_seconds')));
      expect(payload, isNot(contains('proxy_url')));
    },
  );

  test(
    'invalid candidates are reported by index and never become drafts',
    () async {
      final client = AiAssistantClient(
        keyStore: _MemoryKeyStore({'cloud': 'top-secret'}),
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': jsonEncode({
                      'candidates': [
                        _candidateJson('one', '评审'),
                        {'temp_id': 'bad', 'type': 'event'},
                      ],
                    }),
                  },
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      addTearDown(client.close);

      final result = await client.extract(
        provider: _provider,
        text: '安排事项',
        timezone: 'Asia/Shanghai',
      );

      expect(result.candidates, hasLength(1));
      expect(result.issues.single.index, 1);
      expect(result.issues.single.message, contains('title'));
    },
  );
}

const _provider = AiProviderConfig(
  id: 'cloud',
  name: 'Cloud',
  kind: AiProviderKind.openaiCompatible,
  baseUrl: 'https://ai.example.com/v1',
  model: 'test-model',
);

AiCandidate _candidate(String id, String title) => AiCandidate(
  tempId: id,
  type: ItemType.event,
  title: title,
  startAt: DateTime.parse('2026-08-12T09:00:00+08:00'),
  endAt: DateTime.parse('2026-08-12T10:00:00+08:00'),
  confidence: 0.9,
);

Map<String, dynamic> _candidateJson(String id, String title) => {
  'temp_id': id,
  'type': 'event',
  'title': title,
  'start_at': '2026-08-12T09:00:00+08:00',
  'end_at': '2026-08-12T10:00:00+08:00',
  'timezone': 'Asia/Shanghai',
  'confidence': 0.9,
  'source_text_span': {'start': 0, 'end': title.length},
};

class _MemoryKeyStore implements AiApiKeyStore {
  _MemoryKeyStore(this.values);

  final Map<String, String> values;

  @override
  Future<String?> read(String providerId) async => values[providerId];

  @override
  Future<void> write(String providerId, String apiKey) async =>
      values[providerId] = apiKey;

  @override
  Future<void> clear(String providerId) async => values.remove(providerId);
}
