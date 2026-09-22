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
  test('reverse chronological merge restores a valid combined interval', () {
    final earlier = _candidate('earlier', '今天复盘');
    for (final laterEnd in [
      DateTime.parse('2026-08-13T10:00:00+08:00'),
      null,
    ]) {
      final later = AiCandidate(
        tempId: 'later',
        type: ItemType.event,
        title: '明天评审',
        startAt: DateTime.parse('2026-08-13T09:00:00+08:00'),
        endAt: laterEnd,
      );
      final workbench = CandidateWorkbench([later, earlier]);
      final merged = workbench.merge(0, 1);
      final restored = AiCandidate.fromJson(
        jsonDecode(jsonEncode(merged.toJson())) as Map<String, dynamic>,
      );

      expect(restored.startAt, earlier.startAt);
      expect(restored.endAt, laterEnd ?? later.startAt);
    }
  });

  test('optional source spans cannot discard otherwise valid candidates', () {
    for (final span in <Object?>[
      null,
      '明天评审',
      [0, 4],
      {},
      {'start': '0', 'end': '4'},
      {'start': 0.5, 'end': 4},
      {'start': -1, 'end': 4},
      {'start': 4, 'end': 0},
    ]) {
      final candidate = AiCandidate.fromJson({
        ..._candidateJson('one', '评审'),
        'source_text_span': span,
      });

      expect(candidate.sourceTextSpan, isNull, reason: '$span');
    }

    final original = AiCandidate.fromJson(_candidateJson('one', '评审'));
    final restored = AiCandidate.fromJson(original.toJson());
    expect(restored.sourceTextSpan?.start, 0);
    expect(restored.sourceTextSpan?.end, 2);
  });

  test('candidate still rejects missing or invalid schedule times', () {
    for (final fields in [
      {'start_at': null},
      {'start_at': 'not-a-date'},
      {'end_at': '2026-08-12T08:00:00+08:00'},
      {'type': 'task', 'due_at': null},
    ]) {
      expect(
        () => AiCandidate.fromJson({
          ..._candidateJson('one', '评审'),
          ...fields,
          'source_text_span': '评审',
        }),
        throwsFormatException,
      );
    }
  });

  test('editing candidate title preserves location and priority', () {
    final candidate = _candidate(
      'one',
      '评审',
    ).copyWith(location: '会议室', priority: 2);
    final edited = candidate.copyWith(title: '产品评审');
    final restored = AiCandidate.fromJson(edited.toJson());

    expect(restored.title, '产品评审');
    expect(restored.location, '会议室');
    expect(restored.priority, 2);
  });

  test(
    'OpenAI extraction tolerates source text and isolates invalid candidates',
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
                        {
                          ..._candidateJson('one', '评审'),
                          'source_text_span': '明天评审',
                        },
                        _candidateJson('two', '提交报告'),
                        {'temp_id': 'bad', 'type': 'event'},
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
        now: DateTime.parse('2026-09-21T10:00:00+08:00'),
      );

      expect(result.candidates.map((value) => value.title), ['评审', '提交报告']);
      expect(result.issues.single.index, 2);
      expect(result.issues.single.message, contains('title'));
      expect(result.candidates.first.sourceTextSpan, isNull);
      expect(
        captured.url,
        Uri.parse('https://ai.example.com/v1/chat/completions'),
      );
      expect(captured.headers['Authorization'], 'Bearer top-secret');
      expect(captured.body, isNot(contains('top-secret')));
      final payload = jsonDecode(captured.body) as Map<String, dynamic>;
      final prompt = payload['messages'][0]['content'] as String;
      expect(prompt, contains('source_text_span'));
      expect(prompt, contains('"start"'));
      expect(prompt, contains('"end"'));
      expect(prompt, contains('2026-09-21T02:00:00.000Z'));
      expect(prompt, contains('Asia/Shanghai'));
      expect(prompt, contains('明天评审，周五前提交报告'));
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

  test('Ollama extracts candidates and warnings without an API key', () async {
    late http.Request captured;
    final client = AiAssistantClient(
      keyStore: _MemoryKeyStore({}),
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'message': {
              'role': 'assistant',
              'content': jsonEncode({
                'candidates': [
                  {
                    'temp_id': 'report',
                    'type': 'task',
                    'title': '提交报告',
                    'due_at': '2026-09-25T17:00:00+08:00',
                    'timezone': 'Asia/Shanghai',
                  },
                ],
                'warnings': ['已假设截止时间为下午五点'],
              }),
            },
            'done': true,
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    addTearDown(client.close);

    final result = await client.extract(
      provider: const AiProviderConfig(
        id: 'local',
        name: 'Local Ollama',
        kind: AiProviderKind.ollama,
        baseUrl: 'http://localhost:11434',
        model: 'qwen',
        requestParameters: {'temperature': 0.2, 'max_tokens': 512},
      ),
      text: '周五前提交报告',
      timezone: 'Asia/Shanghai',
    );

    expect(captured.url, Uri.parse('http://localhost:11434/api/chat'));
    expect(captured.headers['Authorization'], isNull);
    final payload = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(payload['model'], 'qwen');
    expect(payload['stream'], isFalse);
    expect(payload['format'], 'json');
    expect(payload['options'], {'temperature': 0.2, 'num_predict': 512});
    expect(result.candidates.single.title, '提交报告');
    expect(
      result.candidates.single.dueAt,
      DateTime.parse('2026-09-25T17:00:00+08:00'),
    );
    expect(result.issues, isEmpty);
    expect(result.warnings, ['已假设截止时间为下午五点']);
  });
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
