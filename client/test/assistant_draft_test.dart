import 'dart:async';
import 'dart:io';

import 'package:easy_calendar/ai/ai_assistant_client.dart';
import 'package:easy_calendar/ai/ai_provider.dart';
import 'package:easy_calendar/ai/assistant_models.dart';
import 'package:easy_calendar/application/assistant_controller.dart';
import 'package:easy_calendar/config/app_config.dart';
import 'package:easy_calendar/data/local_item_repository.dart';
import 'package:easy_calendar/domain/item.dart';
import 'package:easy_calendar/domain/recurrence.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory directory;
  late LocalItemRepository repository;
  late AssistantController controller;
  late _AssistantClient client;

  LocalItemRepository openRepository() => LocalItemRepository(
    _config,
    databaseFactory: databaseFactoryFfi,
    databasePath: '${directory.path}/assistant.sqlite3',
  );

  Future<void> reopen() async {
    await controller.flush();
    controller.dispose();
    await repository.close();
    repository = openRepository();
    await repository.initialize();
    controller = AssistantController(repository: repository, client: client);
    await controller.initialize();
    expect(controller.storageError, isNull);
  }

  Future<void> extract() =>
      controller.extract(provider: _provider, timezone: 'Asia/Shanghai');

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('assistant-draft-');
    repository = openRepository();
    await repository.initialize();
    client = _AssistantClient();
    controller = AssistantController(repository: repository, client: client);
    await controller.initialize();
  });
  tearDown(() async {
    await controller.flush();
    controller.dispose();
    await repository.close();
    await directory.delete(recursive: true);
  });

  test(
    'reopening SQLite restores input, mode, edited/split/merged candidates and warnings',
    () async {
      final initialOutbox = await repository.listPendingChanges(
        now: DateTime.now(),
      );
      const input = '  明天评审\n提交报告  ';
      controller.updateText(input);
      controller.setUseAi(true);
      await extract();
      final edited = controller.workbench!.candidates.first.copyWith(
        title: '产品评审和复盘',
        body: '修改后的备注',
        location: '会议室 B',
        priority: 2,
        startAt: DateTime.parse('2026-09-22T10:00:00+08:00'),
        endAt: DateTime.parse('2026-09-22T11:00:00+08:00'),
      );
      final remainingCandidates = controller.workbench!.candidates
          .skip(1)
          .map((candidate) => candidate.toJson())
          .toList();
      controller.edit(0, edited);

      await reopen();

      expect(controller.text, input);
      expect(controller.useAi, isTrue);
      expect(
        controller.workbench!.candidates.map((candidate) => candidate.toJson()),
        [edited.toJson(), ...remainingCandidates],
      );
      controller.split(0);

      await reopen();

      expect(
        controller.workbench!.candidates.map((candidate) => candidate.toJson()),
        [
          edited.copyWith(title: '产品评审').toJson(),
          edited.copyWith(title: '复盘').toJson(),
          ...remainingCandidates,
        ],
      );
      controller.merge(0);

      await reopen();

      expect(
        controller.workbench!.candidates.map((candidate) => candidate.toJson()),
        [
          edited.copyWith(title: '产品评审 / 复盘', body: '修改后的备注\n修改后的备注').toJson(),
          ...remainingCandidates,
        ],
      );
      expect(controller.issues.single.index, 3);
      expect(controller.issues.single.message, '缺少时间');
      expect(controller.warnings, ['已假设会议持续一小时']);
      expect(await repository.listItems(), isEmpty);
      expect(
        (await repository.listPendingChanges(
          now: DateTime.now(),
        )).map((change) => change.changeId),
        initialOutbox.map((change) => change.changeId),
      );
    },
  );

  test(
    'cleared input and rejected or confirmed candidates never return after restart',
    () async {
      controller.updateText('待处理的安排');
      controller.setUseAi(true);
      await extract();
      controller.updateText('');

      await reopen();

      expect(controller.text, '');
      expect(controller.workbench!.candidates, hasLength(3));
      controller.reject(0);
      final confirmed = controller.workbench!.candidates.first;
      await controller.confirm(0, () async {
        await repository.createItem(confirmed.toDraft());
      });

      await reopen();

      expect(controller.workbench!.candidates.single.tempId, 'three');
      expect((await repository.listItems()).single.title, confirmed.title);
      expect(
        (await repository.listPendingChanges(
          now: DateTime.now(),
        )).map((change) => change.entityType),
        ['collection', 'item'],
      );
      controller.rejectAll();
      controller.setUseAi(false);

      await reopen();

      expect(controller.text, '');
      expect(controller.useAi, isFalse);
      expect(controller.workbench!.candidates, isEmpty);
      expect(controller.warnings, isEmpty);
      expect(controller.issues, isEmpty);
    },
  );

  test(
    'failed extraction or confirmation preserves existing draft across restart',
    () async {
      controller.updateText('已有草稿');
      controller.setUseAi(true);
      await extract();
      final original = controller.workbench!.candidates
          .map((candidate) => candidate.toJson())
          .toList();
      controller.updateText('新的输入尚未成功生成');
      client.failure = StateError('Provider offline');

      await extract();

      expect(controller.error, contains('Provider offline'));
      expect(controller.extracting, isFalse);
      expect(controller.text, '新的输入尚未成功生成');
      expect(
        controller.workbench!.candidates.map((candidate) => candidate.toJson()),
        original,
      );
      expect(controller.warnings, ['已假设会议持续一小时']);
      await controller.confirm(
        0,
        () async => throw StateError('Item save failed'),
      );
      expect(controller.error, contains('Item save failed'));
      expect(controller.confirming, isFalse);

      await reopen();

      expect(controller.text, '新的输入尚未成功生成');
      expect(
        controller.workbench!.candidates.map((candidate) => candidate.toJson()),
        original,
      );
      expect(controller.warnings, ['已假设会议持续一小时']);
      expect(await repository.listItems(), isEmpty);
    },
  );

  test(
    'a failed disk save retains current state and retry persists the latest edit',
    () async {
      controller.updateText('已保存');
      controller.setUseAi(true);
      await extract();
      await repository.close();

      controller.updateText('尚未保存的输入');
      await controller.flush();

      expect(controller.storageError, contains('尚未保存'));
      expect(controller.text, '尚未保存的输入');
      expect(controller.workbench!.candidates, hasLength(3));
      await repository.initialize();
      expect((await repository.loadAssistantDraft())!['text'], '已保存');
      controller.retrySave();
      await controller.flush();
      expect(controller.storageError, isNull);

      await reopen();

      expect(controller.text, '尚未保存的输入');
      expect(controller.workbench!.candidates, hasLength(3));
    },
  );

  test(
    'one malformed saved candidate preserves input and other candidates with a visible issue',
    () async {
      const input = '  需要恢复的原始输入\n保留格式  ';
      controller.updateText(input);
      controller.setUseAi(true);
      await extract();
      final expectedCandidates = controller.workbench!.candidates
          .map((candidate) => candidate.toJson())
          .toList();
      final draft = (await repository.loadAssistantDraft())!;
      (draft['candidates'] as List).insert(1, {
        'temp_id': 'corrupt',
        'type': 'event',
        'title': '没有时间的候选',
      });
      await repository.saveAssistantDraft(draft);

      await reopen();

      expect(controller.busy, isFalse);
      expect(controller.text, input);
      expect(controller.useAi, isTrue);
      expect(
        controller.workbench!.candidates.map((candidate) => candidate.toJson()),
        expectedCandidates,
      );
      expect(controller.warnings, ['已假设会议持续一小时']);
      expect(controller.issues, hasLength(2));
      expect(controller.issues.first.message, '缺少时间');
      expect(controller.issues.last.index, 1);
      expect(controller.issues.last.message, contains('草稿候选恢复失败'));
      expect(controller.issues.last.message, contains('start_at'));
    },
  );

  test(
    'initialization can retry after a database read failure without overwriting the draft',
    () async {
      controller.updateText('等待数据库恢复的输入');
      controller.setUseAi(true);
      await extract();
      controller.dispose();
      await repository.close();
      controller = AssistantController(repository: repository, client: client);

      await controller.initialize();

      expect(controller.busy, isTrue);
      expect(controller.storageError, contains('读取助手草稿失败'));
      controller.updateText('读取失败时不能覆盖草稿');
      await repository.initialize();
      await controller.initialize();

      expect(controller.busy, isFalse);
      expect(controller.storageError, isNull);
      expect(controller.text, '等待数据库恢复的输入');
      expect(controller.useAi, isTrue);
      expect(controller.workbench!.candidates, hasLength(3));
      expect((await repository.loadAssistantDraft())!['text'], '等待数据库恢复的输入');
    },
  );

  test(
    'flush waits for edits enqueued during a slow write and persists the latest state',
    () async {
      controller.dispose();
      await repository.close();
      const latestInput = '最后一版\n保留换行  ';
      final delayedRepository = _DelayedDraftRepository(
        '${directory.path}/assistant.sqlite3',
        latestInput,
      );
      repository = delayedRepository;
      await repository.initialize();
      controller = AssistantController(repository: repository, client: client);
      await controller.initialize();
      controller.updateText('第一版');
      await delayedRepository.firstWriteStarted.future;

      var flushed = false;
      final saving = controller.flush().then((_) => flushed = true);
      controller.updateText('第二版');
      controller.setUseAi(true);
      controller.updateText(latestInput);
      delayedRepository.releaseFirstWrite.complete();
      await delayedRepository.latestWriteStarted.future;
      final finishedBeforeLatestWrite = flushed;
      delayedRepository.releaseLatestWrite.complete();
      await saving;

      expect(finishedBeforeLatestWrite, isFalse);
      final saved = (await repository.loadAssistantDraft())!;
      expect(saved['text'], latestInput);
      expect(saved['use_ai'], isTrue);
    },
  );
}

class _AssistantClient extends AiAssistantClient {
  Object? failure;

  @override
  Future<AiExtractionResult> extract({
    required AiProviderConfig provider,
    required String text,
    required String timezone,
    DateTime? now,
  }) async {
    if (failure != null) throw failure!;
    return AiExtractionResult(
      candidates: [
        AiCandidate(
          tempId: 'one',
          type: ItemType.event,
          title: '评审',
          body: '初始备注',
          startAt: DateTime.parse('2026-09-22T09:00:00+08:00'),
          endAt: DateTime.parse('2026-09-22T10:00:00+08:00'),
          location: '会议室 A',
          priority: 1,
          confidence: 0.8,
          reasoning: '根据输入推断',
          sourceTextSpan: const AiTextSpan(start: 2, end: 6),
          reminders: const [
            {'minutes_before': 15, 'enabled': true},
          ],
          recurrence: const RecurrenceRule(
            rrule: 'FREQ=WEEKLY;BYDAY=TU',
            exdates: ['2026-09-29T09:00:00+08:00'],
          ),
        ),
        const AiCandidate(tempId: 'two', type: ItemType.note, title: '提交报告'),
        const AiCandidate(tempId: 'three', type: ItemType.note, title: '等待处理'),
      ],
      issues: const [AiCandidateIssue(index: 3, message: '缺少时间')],
      warnings: const ['已假设会议持续一小时'],
    );
  }

  @override
  void close() {}
}

class _DelayedDraftRepository extends LocalItemRepository {
  _DelayedDraftRepository(String path, this.latestInput)
    : super(_config, databaseFactory: databaseFactoryFfi, databasePath: path);

  final String latestInput;
  final firstWriteStarted = Completer<void>();
  final releaseFirstWrite = Completer<void>();
  final latestWriteStarted = Completer<void>();
  final releaseLatestWrite = Completer<void>();

  @override
  Future<void> saveAssistantDraft(Map<String, dynamic> draft) async {
    if (!firstWriteStarted.isCompleted) {
      firstWriteStarted.complete();
      await releaseFirstWrite.future;
    }
    if (draft['text'] == latestInput) {
      latestWriteStarted.complete();
      await releaseLatestWrite.future;
    }
    await super.saveAssistantDraft(draft);
  }
}

const _provider = AiProviderConfig(
  id: 'test',
  name: 'Test AI',
  kind: AiProviderKind.ollama,
  baseUrl: 'http://localhost:11434',
  model: 'test',
);

const _config = AppConfig(
  appName: 'EasyCalendar',
  locale: Locale('zh', 'CN'),
  timezone: 'Asia/Shanghai',
  defaultCollectionId: 'collection_local',
  defaultCollectionName: '我的日程',
  defaultCollectionColor: Color(0xFF2563EB),
  databaseName: 'assistant-test.sqlite3',
  deviceId: 'assistant-test',
  apiUrl: '',
  syncEnabled: false,
  syncRetryLimit: 8,
  notificationsEnabled: false,
);
