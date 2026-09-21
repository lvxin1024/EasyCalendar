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
import 'package:easy_calendar/features/assistant/assistant_page.dart';
import 'package:easy_calendar/features/shell/home_shell.dart';
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
      expect(find.text('助手草稿尚未保存，请在助手页重试后退出。'), findsOneWidget);
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
