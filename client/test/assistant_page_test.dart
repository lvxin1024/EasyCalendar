import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:easy_calendar/ai/ai_assistant_client.dart';
import 'package:easy_calendar/ai/ai_provider.dart';
import 'package:easy_calendar/ai/assistant_models.dart';
import 'package:easy_calendar/application/item_controller.dart';
import 'package:easy_calendar/application/cycle_controller.dart';
import 'package:easy_calendar/config/app_config.dart';
import 'package:easy_calendar/data/local_item_repository.dart';
import 'package:easy_calendar/data/local_cycle_repository.dart';
import 'package:easy_calendar/domain/item.dart';
import 'package:easy_calendar/domain/recurrence.dart';
import 'package:easy_calendar/features/assistant/assistant_page.dart';
import 'package:easy_calendar/features/editor/item_editor_page.dart';
import 'package:easy_calendar/features/shell/home_shell.dart';
import 'package:easy_calendar/utils/date_formatters.dart';
import 'package:easy_calendar/widget/widget_deep_link_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/data/latest.dart' as tz_data;

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    tz_data.initializeTimeZones();
  });

  testWidgets('preview edits remain drafts until explicitly confirmed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = LocalItemRepository(
      _config,
      databaseFactory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    final controller = ItemController(repository: repository, config: _config);
    final candidate = AiCandidate(
      tempId: 'review',
      type: ItemType.event,
      title: '产品评审',
      body: '讨论新版本',
      startAt: DateTime.parse('2026-10-01T09:00:00+08:00'),
      endAt: DateTime.parse('2026-10-02T10:00:00+08:00'),
      location: '会议室 A',
      reminders: const [
        {'enabled': true, 'minutes_before': 45},
      ],
      recurrence: const RecurrenceRule(
        rrule: 'FREQ=WEEKLY;INTERVAL=2;BYDAY=TH;COUNT=3',
        exdates: ['2026-10-15T09:00:00+08:00'],
      ),
    );
    await tester.runAsync(() async {
      await repository.initialize();
      await repository.savePreferences(
        const ClientPreferences(
          apiUrl: '',
          timezone: 'Asia/Shanghai',
          syncEnabled: false,
          notificationsEnabled: false,
        ),
      );
      await repository.saveAssistantDraft({
        'candidates': [candidate.toJson()],
      });
      await controller.initialize();
      await controller.assistant.initialize();
    });
    await tester.pumpWidget(
      DateFormattingScope(
        clockFormat: ClockFormat.hour24,
        child: MaterialApp(
          home: Scaffold(
            body: AssistantPage(config: _config, controller: controller),
          ),
        ),
      ),
    );
    expect(find.text('日程识别'), findsOneWidget);
    expect(find.text('日程预览'), findsOneWidget);
    expect(find.text('开始：October 1, 2026 · 09:00'), findsOneWidget);
    expect(find.text('结束：October 2, 2026 · 10:00'), findsOneWidget);
    expect(find.text('地点：会议室 A'), findsOneWidget);
    expect(find.text('备注：讨论新版本'), findsOneWidget);

    await tester.runAsync(() => tester.tap(find.text('产品评审')));
    await tester.pumpAndSettle();
    expect(find.byType(ItemEditorPage), findsOneWidget);
    expect(find.text('编辑识别日程'), findsOneWidget);
    expect(find.byTooltip('删除'), findsNothing);
    expect(find.text('09:00'), findsOneWidget);
    expect(find.text('提前 45 分钟'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, '标题'), '已调整评审');
    await tester.enterText(find.widgetWithText(TextFormField, '地点'), '会议室 B');
    await tester.tap(find.byTooltip('清除时间'));
    final tags = find.widgetWithText(TextFormField, '标签');
    await tester.ensureVisible(tags);
    await tester.enterText(tags, '工作, 产品');
    await tester.runAsync(() => tester.tap(find.text('保存候选')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await controller.assistant.flush();
      expect(await repository.listItems(), isEmpty);
      final saved = (await repository.loadAssistantDraft())!;
      final restored = AiCandidate.fromJson(
        Map<String, dynamic>.from((saved['candidates'] as List).single as Map),
      );
      expect(restored.title, '已调整评审');
      expect(restored.startAt, candidate.startAt);
      expect(restored.endAt, isNull);
      expect(restored.location, '会议室 B');
      expect(restored.tags, ['工作', '产品']);
      expect(restored.recurrence!.toJson(), candidate.recurrence!.toJson());
      expect(restored.toDraft().reminderMinutes, 45);
    });
    await tester.pump();
    expect(find.text('地点：会议室 B'), findsOneWidget);
    expect(find.textContaining('结束：'), findsNothing);
    await tester.tap(find.text('已调整评审'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '标题'), '不要保存');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('已调整评审'), findsOneWidget);

    await tester.runAsync(() async {
      final confirmed = Completer<void>();
      void onConfirmed() {
        if (!controller.assistant.confirming && !confirmed.isCompleted) {
          confirmed.complete();
        }
      }

      controller.assistant.addListener(onConfirmed);
      await tester.tap(find.text('确认'));
      await confirmed.future.timeout(const Duration(seconds: 10));
      controller.assistant.removeListener(onConfirmed);
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await controller.assistant.flush();
      final item = (await repository.listItems()).single;
      expect(item.title, '已调整评审');
      expect(item.startAt, candidate.startAt);
      expect(item.endAt, isNull);
      expect(item.location, '会议室 B');
      expect(item.tags, ['工作', '产品']);
    });
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      controller.dispose();
      await repository.close();
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'normal exit waits for drafts and refuses unfinished work or failed saves',
    (tester) async {
      final repository = _BlockedDraftRepository();
      final client = _DeferredAssistantClient();
      final controller = ItemController(
        repository: repository,
        config: _config,
        aiAssistantClient: client,
      );
      final cycle = CycleController(
        repository: LocalCycleRepository(
          databaseProvider: repository.openSharedDatabase,
        ),
      );
      final links = WidgetDeepLinkController();
      await tester.runAsync(() async {
        await repository.initialize();
        await controller.assistant.initialize();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: HomeShell(
            config: _config,
            controller: controller,
            cycleController: cycle,
            widgetDeepLinks: links,
          ),
        ),
      );
      await tester.runAsync(() async {
        controller.assistant.updateText('退出前刚输入的内容');
        var exitCompleted = false;
        final exit = tester.binding.handleRequestAppExit().then((response) {
          exitCompleted = true;
          return response;
        });
        await Future<void>.delayed(Duration.zero);
        expect(exitCompleted, isFalse);
        repository.allowSave.complete();
        expect(await exit, AppExitResponse.exit);
        expect((await repository.loadAssistantDraft())!['text'], '退出前刚输入的内容');

        controller.assistant.setUseAi(true);
        final extracting = controller.assistant.extract(
          provider: _provider,
          timezone: _config.timezone,
        );
        expect(
          await tester.binding.handleRequestAppExit(),
          AppExitResponse.cancel,
        );
        client.result.complete(
          const AiExtractionResult(
            candidates: [
              AiCandidate(
                tempId: 'confirming',
                type: ItemType.note,
                title: '确认中',
              ),
            ],
          ),
        );
        await extracting;

        final saveItem = Completer<void>();
        final confirming = controller.assistant.confirm(
          0,
          () => saveItem.future,
        );
        expect(
          await tester.binding.handleRequestAppExit(),
          AppExitResponse.cancel,
        );
        saveItem.complete();
        await confirming;
        expect(
          await tester.binding.handleRequestAppExit(),
          AppExitResponse.exit,
        );
        expect((await repository.loadAssistantDraft())!['candidates'], isEmpty);
        ScaffoldMessenger.of(
          tester.element(find.byType(HomeShell)),
        ).clearSnackBars();

        await repository.close();
        controller.assistant.updateText('未能保存的内容');
        expect(
          await tester.binding.handleRequestAppExit(),
          AppExitResponse.cancel,
        );
        expect(controller.assistant.text, '未能保存的内容');
      });
      await tester.pump();
      expect(find.text('日程识别草稿尚未保存，请在日程识别页重试后退出。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      cycle.dispose();
      links.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('mode, input, and AI results survive leaving the assistant', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = LocalItemRepository(
      _config,
      databaseFactory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    final client = _DeferredAssistantClient();
    final controller = ItemController(
      repository: repository,
      config: _config,
      aiAssistantClient: client,
    );
    await tester.runAsync(() async {
      await repository.initialize();
      await repository.savePreferences(
        const ClientPreferences(
          apiUrl: '',
          syncEnabled: false,
          notificationsEnabled: false,
          aiProviders: [_provider],
        ),
      );
      await controller.initialize();
      await controller.assistant.initialize();
    });
    expect(controller.error, isNull);
    final page = MaterialApp(
      home: Scaffold(
        body: AssistantPage(config: _config, controller: controller),
      ),
    );
    await tester.pumpWidget(page);

    // Configuring a provider must still allow explicit local-only parsing.
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    await tester.runAsync(() async {
      await tester.enterText(find.byType(TextField), '明天上午9点开会');
      await tester.tap(find.text('生成候选'));
      await controller.assistant.flush();
    });
    await tester.pumpAndSettle();
    expect(client.calls, 0);
    expect(find.widgetWithText(ListTile, '明天上午9点开会'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: Text('其他页面')));
    await tester.pumpWidget(page);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '明天上午9点开会',
    );
    expect(find.widgetWithText(ListTile, '明天上午9点开会'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.byType(Switch));
      await controller.assistant.flush();
    });
    await tester.pump();
    await tester.runAsync(() => tester.tap(find.text('生成候选')));
    await tester.pump();
    expect(client.calls, 1);
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '生成候选'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确认'))
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(const MaterialApp(home: Text('其他页面')));
    expect(client.closed, isFalse);

    await tester.runAsync(() async {
      final completed = Completer<void>();
      void onCompleted() {
        if (!controller.assistant.extracting && !completed.isCompleted) {
          completed.complete();
        }
      }

      controller.assistant.addListener(onCompleted);
      client.result.complete(
        const AiExtractionResult(
          candidates: [
            AiCandidate(tempId: 'remote', type: ItemType.note, title: 'AI 候选'),
          ],
        ),
      );
      await completed.future.timeout(const Duration(seconds: 10));
      controller.assistant.removeListener(onCompleted);
    });
    await tester.pumpWidget(page);
    expect(find.text('AI 候选'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);

    // Clearing input must leave already generated candidates visible.
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('清空输入'));
      await controller.assistant.flush();
    });
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
    expect(find.text('AI 候选'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await controller.assistant.flush();
      controller.dispose();
      await repository.close();
    });
    expect(client.closed, isTrue);
  });

  testWidgets(
    'empty input or no enabled provider cannot discard candidates or call AI',
    (tester) async {
      final repository = LocalItemRepository(
        _config,
        databaseFactory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath,
      );
      final client = _DeferredAssistantClient();
      late final ItemController controller;
      await tester.runAsync(() async {
        controller = ItemController(
          repository: repository,
          config: _config,
          aiAssistantClient: client,
        );
        await repository.initialize();
        await controller.assistant.initialize();
        controller.assistant.updateText('明天开会');
        await controller.assistant.extract(
          provider: null,
          timezone: _config.timezone,
        );
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AssistantPage(config: _config, controller: controller),
          ),
        ),
      );
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('清空输入'));
        await controller.assistant.flush();
      });
      await tester.tap(find.text('生成候选'));
      await tester.pump();
      expect(find.text('请输入需要拆分的文本'), findsOneWidget);

      await tester.runAsync(() async {
        await tester.enterText(find.byType(TextField), '新安排');
        await tester.tap(find.byType(Switch));
        await controller.assistant.flush();
      });
      await tester.pump();
      await tester.tap(find.text('生成候选'));
      await tester.pump();
      expect(find.textContaining('请先在设置中启用并配置 AI Provider'), findsOneWidget);

      await tester.runAsync(
        () => controller.savePreferences(
          controller.preferences.copyWith(
            aiProviders: [_provider.copyWith(enabled: false)],
          ),
        ),
      );
      await tester.tap(find.text('生成候选'));
      await tester.pump();
      expect(find.textContaining('请先在设置中启用并配置 AI Provider'), findsOneWidget);
      expect(find.widgetWithText(ListTile, '明天开会'), findsOneWidget);
      expect(client.calls, 0);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        controller.dispose();
        await repository.close();
      });
    },
  );
}

class _DeferredAssistantClient extends AiAssistantClient {
  late final result = Completer<AiExtractionResult>();
  int calls = 0;
  bool closed = false;

  @override
  Future<AiExtractionResult> extract({
    required AiProviderConfig provider,
    required String text,
    required String timezone,
    DateTime? now,
  }) {
    calls++;
    return result.future;
  }

  @override
  void close() => closed = true;
}

class _BlockedDraftRepository extends LocalItemRepository {
  _BlockedDraftRepository()
    : super(
        _config,
        databaseFactory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath,
      );

  late final allowSave = Completer<void>();

  @override
  Future<void> saveAssistantDraft(Map<String, dynamic> draft) async {
    await allowSave.future;
    await super.saveAssistantDraft(draft);
  }
}

const _provider = AiProviderConfig(
  id: 'local',
  name: 'Local AI',
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
