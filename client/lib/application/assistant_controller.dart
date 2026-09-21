import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ai/ai_assistant_client.dart';
import '../ai/ai_provider.dart';
import '../ai/assistant_models.dart';
import '../ai/local_rule_parser.dart';
import '../data/item_repository.dart';
import '../utils/configured_time.dart';

/// Keeps the workbench alive across pages and saves every edit to local SQLite.
class AssistantController extends ChangeNotifier {
  AssistantController({required this.repository, AiAssistantClient? client})
    : _client = client ?? AiAssistantClient();

  final ItemRepository repository;
  final AiAssistantClient _client;
  String text = '';
  bool useAi = false;
  CandidateWorkbench? workbench;
  List<AiCandidateIssue> issues = const [];
  List<String> warnings = const [];
  bool initialized = false;
  bool extracting = false;
  bool confirming = false;
  String? error;
  String? storageError;
  Future<void>? _initialization;
  Future<void> _pendingSave = Future.value();
  bool _disposed = false;

  bool get busy => !initialized || extracting || confirming;

  Future<void> initialize() => _initialization ??= _load();

  Future<void> _load() async {
    try {
      final draft = await repository.loadAssistantDraft();
      if (_disposed) return;
      if (draft != null) {
        text = draft['text'] as String? ?? '';
        useAi = draft['use_ai'] as bool? ?? false;
        issues = [
          for (final issue in draft['issues'] as List? ?? const [])
            AiCandidateIssue(
              index: issue['index'] as int,
              message: issue['message'] as String,
            ),
        ];
        final candidates = draft['candidates'] as List?;
        if (candidates != null) {
          final restored = <AiCandidate>[];
          for (var index = 0; index < candidates.length; index++) {
            try {
              restored.add(
                AiCandidate.fromJson(
                  Map<String, dynamic>.from(candidates[index] as Map),
                ),
              );
            } catch (caught) {
              issues.add(
                AiCandidateIssue(index: index, message: '草稿候选恢复失败：$caught'),
              );
            }
          }
          workbench = CandidateWorkbench(restored);
        }
        warnings = List<String>.from(draft['warnings'] as List? ?? const []);
      }
      initialized = true;
      storageError = null;
    } catch (caught) {
      storageError = '读取助手草稿失败：$caught';
      _initialization = null;
    }
    _notify();
  }

  void updateText(String value) {
    if (!initialized || text == value) return;
    text = value;
    _changed();
  }

  void setUseAi(bool value) {
    if (busy || useAi == value) return;
    useAi = value;
    error = null;
    _changed();
  }

  Future<void> extract({
    required AiProviderConfig? provider,
    required String timezone,
  }) async {
    if (busy) return;
    final input = text.trim();
    if (input.isEmpty) {
      error = '请输入需要拆分的文本';
      _notify();
      return;
    }
    if (useAi && provider == null) {
      error = '请先在设置中启用并配置 AI Provider，或切换到传统规则解析。';
      _notify();
      return;
    }
    extracting = true;
    error = null;
    _notify();
    try {
      final result = useAi
          ? await _client.extract(
              provider: provider!,
              text: input,
              timezone: timezone,
            )
          : const LocalRuleParser().extract(
              input,
              now: configuredNow(),
              timezone: timezone,
            );
      if (_disposed) return;
      workbench = CandidateWorkbench(result.candidates);
      issues = result.issues;
      warnings = result.warnings;
      _changed();
      await flush();
    } catch (caught) {
      error = '$caught';
    } finally {
      extracting = false;
      _notify();
    }
  }

  void edit(int index, AiCandidate candidate) {
    if (busy) return;
    workbench!.edit(index, candidate);
    _changed();
  }

  void reject(int index) {
    if (busy) return;
    workbench!.reject(index);
    _changed();
  }

  void rejectAll() {
    if (busy) return;
    workbench = CandidateWorkbench(const []);
    issues = const [];
    warnings = const [];
    _changed();
  }

  void split(int index) {
    if (busy) return;
    final original = workbench!.candidates[index];
    final parts = original.title
        .split(RegExp(r'\s*(?:、|和|及|与|以及|,|，)\s*'))
        .where((value) => value.trim().isNotEmpty)
        .toList();
    if (parts.length < 2) {
      error = '标题中没有可拆分的多个安排';
      _notify();
      return;
    }
    workbench!.split(index, [
      for (final part in parts) original.copyWith(title: part.trim()),
    ]);
    _changed();
  }

  void merge(int index) {
    if (busy) return;
    workbench!.merge(index, index + 1);
    _changed();
  }

  Future<void> confirm(int index, Future<void> Function() saveItem) async {
    if (busy) return;
    confirming = true;
    error = null;
    _notify();
    try {
      await saveItem();
      if (_disposed) return;
      workbench!.reject(index);
      _changed();
      await flush();
    } catch (caught) {
      error = '确认失败：$caught';
    } finally {
      confirming = false;
      _notify();
    }
  }

  void _changed() {
    final draft = {
      'text': text,
      'use_ai': useAi,
      'candidates': workbench?.candidates
          .map((value) => value.toJson())
          .toList(),
      'issues': [
        for (final issue in issues)
          {'index': issue.index, 'message': issue.message},
      ],
      'warnings': warnings,
    };
    // Save in edit order so an older asynchronous write cannot replace new input.
    _pendingSave = _pendingSave.then((_) async {
      try {
        await repository.saveAssistantDraft(draft);
        storageError = null;
      } catch (caught) {
        storageError = '助手草稿尚未保存：$caught';
      }
      _notify();
    });
    _notify();
  }

  Future<void> flush() async {
    while (true) {
      final pending = _pendingSave;
      await pending;
      if (identical(pending, _pendingSave)) return;
    }
  }

  void retrySave() {
    if (initialized) _changed();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _client.close();
    super.dispose();
  }
}
