import 'dart:async';

import 'package:flutter/material.dart';

import '../../ai/ai_provider.dart';
import '../../ai/assistant_models.dart';
import '../../application/assistant_controller.dart';
import '../../application/item_controller.dart';
import '../../config/app_config.dart';
import '../../domain/item.dart';

class AssistantPage extends StatefulWidget {
  const AssistantPage({
    super.key,
    required this.config,
    required this.controller,
  });

  final AppConfig config;
  final ItemController controller;

  @override
  State<AssistantPage> createState() => _AssistantPageState();
}

class _AssistantPageState extends State<AssistantPage> {
  final _textController = TextEditingController();
  late final AssistantController _assistant;

  CandidateWorkbench? get _workbench => _assistant.workbench;

  @override
  void initState() {
    super.initState();
    _assistant = widget.controller.assistant;
    _textController.text = _assistant.text;
    _assistant.addListener(_draftChanged);
    unawaited(_assistant.initialize());
  }

  @override
  void dispose() {
    _assistant.removeListener(_draftChanged);
    _textController.dispose();
    super.dispose();
  }

  void _draftChanged() {
    if (_textController.text != _assistant.text) {
      _textController.value = TextEditingValue(
        text: _assistant.text,
        selection: TextSelection.collapsed(offset: _assistant.text.length),
      );
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
        child: Row(
          children: [
            Text('AI 助手', style: Theme.of(context).textTheme.headlineSmall),
            const Spacer(),
            if (_workbench != null)
              TextButton.icon(
                onPressed: _assistant.busy || _workbench!.candidates.isEmpty
                    ? null
                    : _assistant.rejectAll,
                icon: const Icon(Icons.clear_all),
                label: const Text('清空候选'),
              ),
          ],
        ),
      ),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 96),
          children: [
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('调用 AI'),
              subtitle: Text(
                _assistant.useAi
                    ? (_provider == null
                          ? '请先在设置中配置并启用 AI Provider'
                          : '使用 ${_provider!.name} 生成候选')
                    : '传统规则解析 · 本地运行，无需联网',
              ),
              value: _assistant.useAi,
              onChanged: _assistant.busy ? null : _assistant.setUseAi,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _textController,
              enabled: _assistant.initialized,
              onChanged: _assistant.updateText,
              minLines: 4,
              maxLines: 8,
              decoration: InputDecoration(
                labelText: '输入安排或 Due',
                hintText: '例如：明天下午三点评审，周五前提交报告',
                alignLabelWithHint: true,
                prefixIcon: const Icon(Icons.edit_note_outlined),
                suffixIcon: IconButton(
                  tooltip: '清空输入',
                  onPressed:
                      _assistant.initialized && _assistant.text.isNotEmpty
                      ? () => _assistant.updateText('')
                      : null,
                  icon: const Icon(Icons.close),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _assistant.busy ? null : _extract,
                icon: _assistant.extracting
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome),
                label: const Text('生成候选'),
              ),
            ),
            if (_assistant.storageError != null) ...[
              const SizedBox(height: 12),
              Text(
                _assistant.storageError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () {
                    if (_assistant.initialized) {
                      _assistant.retrySave();
                    } else {
                      unawaited(_assistant.initialize());
                    }
                  },
                  child: const Text('重试保存或恢复草稿'),
                ),
              ),
            ],
            if (_assistant.error != null) ...[
              const SizedBox(height: 12),
              Text(
                _assistant.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            for (final warning in _assistant.warnings)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('提醒：$warning'),
              ),
            for (final issue in _assistant.issues)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '候选 ${issue.index + 1} 无效：${issue.message}',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (_workbench != null) ...[
              const SizedBox(height: 24),
              Text('候选预览', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              if (_workbench!.candidates.isEmpty)
                const Text('没有待确认候选项')
              else
                for (
                  var index = 0;
                  index < _workbench!.candidates.length;
                  index++
                )
                  _CandidateTile(
                    candidate: _workbench!.candidates[index],
                    onEdit: _assistant.busy ? null : () => _edit(index),
                    onReject: _assistant.busy
                        ? null
                        : () => _assistant.reject(index),
                    onConfirm: _assistant.busy ? null : () => _confirm(index),
                    onSplit: _assistant.busy
                        ? null
                        : () => _assistant.split(index),
                    onMerge:
                        !_assistant.busy &&
                            index + 1 < _workbench!.candidates.length
                        ? () => _assistant.merge(index)
                        : null,
                  ),
            ],
          ],
        ),
      ),
    ],
  );

  AiProviderConfig? get _provider {
    final candidates = widget.controller.aiProviders.where(
      (value) => value.enabled,
    );
    return candidates.isEmpty ? null : candidates.first;
  }

  Future<void> _extract() => _assistant.extract(
    provider: _provider,
    timezone: widget.controller.activeTimezone,
  );

  Future<void> _edit(int index) async {
    final candidate = _workbench!.candidates[index];
    final title = await showDialog<String>(
      context: context,
      builder: (context) {
        final controller = TextEditingController(text: candidate.title);
        return AlertDialog(
          title: const Text('编辑候选标题'),
          content: TextField(controller: controller, autofocus: true),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
    if (title == null || title.isEmpty || !mounted) return;
    _assistant.edit(index, candidate.copyWith(title: title));
  }

  Future<void> _confirm(int index) async {
    final candidate = _workbench!.candidates[index];
    await _assistant.confirm(index, () async {
      await widget.controller.saveItem(draft: candidate.toDraft());
    });
  }
}

class _CandidateTile extends StatelessWidget {
  const _CandidateTile({
    required this.candidate,
    required this.onEdit,
    required this.onReject,
    required this.onConfirm,
    required this.onSplit,
    required this.onMerge,
  });

  final AiCandidate candidate;
  final VoidCallback? onEdit;
  final VoidCallback? onReject;
  final VoidCallback? onConfirm;
  final VoidCallback? onSplit;
  final VoidCallback? onMerge;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 10),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              candidate.type == ItemType.task
                  ? Icons.check_circle_outline
                  : Icons.event_outlined,
            ),
            title: Text(candidate.title),
            subtitle: Text(
              '置信度 ${(candidate.confidence * 100).round()}% · ${candidate.reasoning ?? '结构化候选'}',
            ),
          ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 4,
            children: [
              IconButton(
                tooltip: '编辑',
                onPressed: onEdit,
                icon: const Icon(Icons.edit_outlined),
              ),
              IconButton(
                tooltip: '拆分',
                onPressed: onSplit,
                icon: const Icon(Icons.call_split_outlined),
              ),
              IconButton(
                tooltip: '合并下一项',
                onPressed: onMerge,
                icon: const Icon(Icons.merge_outlined),
              ),
              IconButton(
                tooltip: '拒绝',
                onPressed: onReject,
                icon: const Icon(Icons.close),
              ),
              FilledButton.icon(
                onPressed: onConfirm,
                icon: const Icon(Icons.check),
                label: const Text('确认'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
