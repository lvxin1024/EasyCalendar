import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../application/item_controller.dart';
import '../../data/transfer_api_client.dart';

class TransferPage extends StatefulWidget {
  const TransferPage({
    super.key,
    required this.controller,
  });

  final ItemController controller;

  @override
  State<TransferPage> createState() => _TransferPageState();
}

class _TransferPageState extends State<TransferPage> {
  final _client = TransferApiClient();
  final _uuid = const Uuid();
  String? _previewContent;
  String? _previewFormat; // 'json' or 'ics'
  String? _previewCollectionId;
  TransferResult? _previewResult;
  bool _busy = false;
  String? _statusMessage;
  bool _statusError = false;

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
        child: Text('导入导出', style: Theme.of(context).textTheme.headlineSmall),
      ),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 96),
          children: [
            _SectionLabel(label: 'JSON 备份'),
            const SizedBox(height: 8),
            Text(
              '导出所有数据为 JSON 文件，可用于完整备份和恢复。'
              '包含 Collections、事项、订阅和同步状态。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : _exportJson,
                  icon: const Icon(Icons.file_download_outlined),
                  label: const Text('导出 JSON 备份'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : _pickAndPreviewJsonImport,
                  icon: const Icon(Icons.file_upload_outlined),
                  label: const Text('导入 JSON 备份'),
                ),
              ],
            ),
            const SizedBox(height: 24),
            _SectionLabel(label: 'ICS 日历'),
            const SizedBox(height: 8),
            Text(
              '导入外部日历应用的 .ics 文件，或导出 Event 为 ICS 格式。'
              '需要连接到同步服务。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : _exportIcs,
                  icon: const Icon(Icons.calendar_month_outlined),
                  label: const Text('导出 ICS'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : _pickAndImportIcs,
                  icon: const Icon(Icons.calendar_view_week_outlined),
                  label: const Text('导入 ICS 文件'),
                ),
              ],
            ),
            if (_statusMessage != null) ...[
              const SizedBox(height: 24),
              _StatusBanner(
                message: _statusMessage!,
                isError: _statusError,
                onDismiss: () => setState(() => _statusMessage = null),
              ),
            ],
            if (_previewResult != null) ...[
              const SizedBox(height: 24),
              _SectionLabel(label: '导入预览'),
              _PreviewCard(result: _previewResult!),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: _busy ? null : _commitImport,
                    icon: const Icon(Icons.check),
                    label: const Text('确认导入'),
                  ),
                  OutlinedButton(
                    onPressed: _busy ? null : _clearPreview,
                    child: const Text('取消'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    ],
  );

  void _showStatus(String message, {bool error = false}) {
    setState(() {
      _statusMessage = message;
      _statusError = error;
    });
  }

  void _clearPreview() {
    setState(() {
      _previewResult = null;
      _previewContent = null;
      _previewFormat = null;
      _previewCollectionId = null;
    });
  }

  Future<void> _exportJson() async {
    setState(() => _busy = true);
    try {
      final backup = await widget.controller.exportLocalJsonBackup();
      final directory = await getApplicationSupportDirectory();
      final timestamp = DateTime.now()
          .toUtc()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final file = File(
        '${directory.path}${Platform.pathSeparator}easycalendar-backup-$timestamp.json',
      );
      await file.writeAsString(backup, flush: true);
      _showStatus('备份已保存到：${file.path}');
    } catch (error) {
      _showStatus('导出失败：$error', error: true);
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _pickAndPreviewJsonImport() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final bytes = picked.files.single.bytes;
    if (bytes == null) {
      _showStatus('无法读取文件', error: true);
      return;
    }
    final content = utf8.decode(bytes);
    setState(() => _busy = true);
    try {
      final result = await widget.controller.previewLocalJsonImport(content);
      if (!mounted) return;
      setState(() {
        _previewContent = content;
        _previewFormat = 'json';
        _previewResult = result;
      });
      if (result.issues.isNotEmpty) {
        _showStatus(
          '预览完成，发现 ${result.issues.length} 个问题',
          error: true,
        );
      } else {
        _showStatus('预览完成，可以确认导入');
      }
    } catch (error) {
      if (!mounted) return;
      _showStatus('预览失败：$error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _commitImport() async {
    if (_previewContent == null || _previewFormat == null) return;
    setState(() => _busy = true);
    try {
      if (_previewFormat == 'json') {
        await widget.controller.commitLocalJsonImport(_previewContent!);
      } else if (_previewFormat == 'ics') {
        final prefs = widget.controller.preferences;
        final serverUrl = Uri.parse(prefs.featureApiUrl);
        final token = await _readSyncToken();
        if (token == null) {
          _showStatus('请先配置访问令牌', error: true);
          return;
        }
        await _client.importContent(
          serverUrl: serverUrl,
          token: token,
          idempotencyKey: 'ics_commit_${_uuid.v4()}',
          format: 'ics',
          mode: 'commit',
          strategy: 'merge',
          content: _previewContent!,
          collectionId: _previewCollectionId,
        );
      }
      if (!mounted) return;
      _showStatus('导入完成');
      await widget.controller.refresh();
      _clearPreview();
    } catch (error) {
      if (!mounted) return;
      _showStatus('导入失败：$error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _readSyncToken() async {
    final tokenStore = widget.controller.syncCoordinator?.tokenStore;
    if (tokenStore == null) return null;
    return tokenStore.read();
  }

  Future<void> _exportIcs() async {
    final prefs = widget.controller.preferences;
    if (prefs.featureApiUrl.isEmpty) {
      _showStatus('ICS 导出需要配置功能服务', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final serverUrl = Uri.parse(prefs.featureApiUrl);
      final token = await _readSyncToken();
      if (token == null) {
        _showStatus('请先配置访问令牌', error: true);
        return;
      }
      final ics = await _client.exportIcs(
        serverUrl: serverUrl,
        token: token,
      );
      final directory = await getApplicationSupportDirectory();
      final timestamp = DateTime.now()
          .toUtc()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final file = File(
        '${directory.path}${Platform.pathSeparator}easycalendar-events-$timestamp.ics',
      );
      await file.writeAsString(ics, flush: true);
      _showStatus('ICS 已保存到：${file.path}');
    } catch (error) {
      _showStatus('ICS 导出失败：$error', error: true);
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _pickAndImportIcs() async {
    final prefs = widget.controller.preferences;
    if (prefs.featureApiUrl.isEmpty) {
      _showStatus('ICS 导入需要配置功能服务', error: true);
      return;
    }
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['ics'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final bytes = picked.files.single.bytes;
    if (bytes == null) {
      _showStatus('无法读取文件', error: true);
      return;
    }
    final content = utf8.decode(bytes);
    setState(() => _busy = true);
    try {
      final serverUrl = Uri.parse(prefs.featureApiUrl);
      final token = await _readSyncToken();
      if (token == null) {
        _showStatus('请先配置访问令牌', error: true);
        return;
      }
      final preview = await _client.importContent(
        serverUrl: serverUrl,
        token: token,
        idempotencyKey: 'ics_preview_${_uuid.v4()}',
        format: 'ics',
        mode: 'preview',
        strategy: 'merge',
        content: content,
      );
      if (!mounted) return;
      setState(() {
        _previewContent = content;
        _previewFormat = 'ics';
        _previewResult = preview;
      });
      if (preview.issues.isNotEmpty) {
        _showStatus(
          '预览完成，发现 ${preview.issues.length} 个问题',
          error: true,
        );
      } else {
        _showStatus('预览完成，可以确认导入');
      }
    } catch (error) {
      if (!mounted) return;
      _showStatus('ICS 导入失败：$error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Text(
    label,
    style: Theme.of(context).textTheme.titleSmall,
  );
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    required this.message,
    required this.isError,
    required this.onDismiss,
  });

  final String message;
  final bool isError;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Material(
    color: isError ? const Color(0xFFFEF2F2) : const Color(0xFFF0FDF4),
    borderRadius: BorderRadius.circular(8),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.check_circle_outline,
            color: isError ? const Color(0xFFB42318) : const Color(0xFF0F766E),
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: isError
                    ? const Color(0xFF7F1D1D)
                    : const Color(0xFF064E3B),
              ),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            onPressed: onDismiss,
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    ),
  );
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.result});

  final TransferResult result;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('格式：${result.format.toUpperCase()}', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 10),
          _CountRow(label: '将创建', counts: result.created),
          _CountRow(label: '将跳过（重复）', counts: result.skipped),
          _CountRow(label: '冲突', counts: result.conflicts),
          if (result.issues.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              '问题 (${result.issues.length})：',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
            const SizedBox(height: 4),
            for (final issue in result.issues.take(10))
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  '· [${issue.resourceType}] ${issue.message}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            if (result.issues.length > 10)
              Text(
                '... 还有 ${result.issues.length - 10} 个问题',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ],
      ),
    ),
  );
}

class _CountRow extends StatelessWidget {
  const _CountRow({required this.label, required this.counts});

  final String label;
  final Map<String, int> counts;

  @override
  Widget build(BuildContext context) {
    if (counts.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        '$label：${counts.entries.map((e) => '${e.value} ${_labelName(e.key)}').join('、')}',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }

  String _labelName(String key) => switch (key) {
    'collections' => 'Collections',
    'items' => '事项',
    'subscriptions' => '订阅',
    'outbox' => '同步变更',
    'sync_state' => '同步状态',
    _ => key,
  };
}
