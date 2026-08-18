import 'package:flutter/material.dart';

import '../../ai/ai_assistant_client.dart';
import '../../ai/local_rule_parser.dart';
import '../../ai/ai_provider.dart';
import '../../ai/assistant_models.dart';
import '../../application/item_controller.dart';
import '../../config/app_config.dart';
import '../../domain/item.dart';
import '../../utils/configured_time.dart';

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
  late final AiAssistantClient _client;
  static const _localParser = LocalRuleParser();
  CandidateWorkbench? _workbench;
  List<AiCandidateIssue> _candidateIssues = const [];
  List<String> _warnings = const [];
  bool _extracting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _client = AiAssistantClient();
  }

  @override
  void dispose() {
    _textController.dispose();
    _client.close();
    super.dispose();
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
                onPressed: _workbench!.candidates.isEmpty ? null : _rejectAll,
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
            TextField(
              controller: _textController,
              minLines: 4,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: '输入安排或 Due',
                hintText: '例如：明天下午三点评审，周五前提交报告',
                alignLabelWithHint: true,
                prefixIcon: Icon(Icons.edit_note_outlined),
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _extracting ? null : _extract,
                icon: _extracting
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome),
                label: const Text('生成候选'),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            for (final warning in _warnings)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('提醒：$warning'),
              ),
            for (final issue in _candidateIssues)
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
                    onEdit: () => _edit(index),
                    onReject: () => _reject(index),
                    onConfirm: () => _confirm(index),
                    onSplit: () => _split(index),
                    onMerge: index + 1 < _workbench!.candidates.length
                        ? () => _merge(index)
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

  Future<void> _extract() async {
    final text = _textController.text.trim();
    final provider = _provider;
    if (text.isEmpty) {
      setState(() => _error = '请输入需要拆分的文本');
      return;
    }
    setState(() {
      _extracting = true;
      _error = null;
      _candidateIssues = const [];
      _warnings = const [];
    });
    try {
      final result = provider == null
          ? _localParser.extract(
              text,
              now: configuredNow(),
              timezone: widget.controller.preferences.timezone,
            )
          : await _client.extract(
              provider: provider,
              text: text,
              timezone: widget.controller.preferences.timezone,
            );
      if (!mounted) return;
      setState(() {
        _workbench = CandidateWorkbench(result.candidates);
        _candidateIssues = result.issues;
        _warnings = result.warnings;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _extracting = false);
    }
  }

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
    setState(() => _workbench!.edit(index, candidate.copyWith(title: title)));
  }

  void _reject(int index) => setState(() => _workbench!.reject(index));

  void _rejectAll() =>
      setState(() => _workbench = CandidateWorkbench(const []));

  Future<void> _confirm(int index) async {
    final candidate = _workbench!.candidates[index];
    try {
      await widget.controller.saveItem(draft: candidate.toDraft());
      if (mounted) setState(() => _workbench!.reject(index));
    } catch (error) {
      if (mounted) setState(() => _error = '确认失败：$error');
    }
  }

  void _split(int index) {
    final original = _workbench!.candidates[index];
    final parts = original.title
        .split(RegExp(r'\s*(?:、|和|及|与|以及|,|，)\s*'))
        .where((value) => value.trim().isNotEmpty)
        .toList();
    if (parts.length < 2) {
      setState(() => _error = '标题中没有可拆分的多个安排');
      return;
    }
    setState(
      () => _workbench!.split(index, [
        for (var part = 0; part < parts.length; part++)
          original.copyWith(title: parts[part].trim()),
      ]),
    );
  }

  void _merge(int index) => setState(() => _workbench!.merge(index, index + 1));
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
  final VoidCallback onEdit;
  final VoidCallback onReject;
  final VoidCallback onConfirm;
  final VoidCallback onSplit;
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
