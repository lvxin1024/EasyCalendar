import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../application/item_controller.dart';
import '../../data/transfer_models.dart';

class TransferPage extends StatefulWidget {
  const TransferPage({super.key, required this.controller});

  final ItemController controller;

  @override
  State<TransferPage> createState() => _TransferPageState();
}

class _TransferPageState extends State<TransferPage> {
  String? _previewContent;
  String? _previewFormat; // 'json' or 'ics'
  TransferResult? _previewResult;
  bool _busy = false;
  String? _statusMessage;
  bool _statusError = false;
  List<LocalDatabaseBackup> _backups = const [];

  @override
  void initState() {
    super.initState();
    _loadBackups();
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
            _SectionLabel(label: '本地恢复点'),
            const SizedBox(height: 8),
            Text(
              '数据库升级前会自动创建恢复点，也可以随时手动创建。恢复前会再保留当前状态。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : _createBackup,
                  icon: const Icon(Icons.add_to_drive_outlined),
                  label: const Text('创建恢复点'),
                ),
                IconButton(
                  tooltip: '刷新恢复点',
                  onPressed: _busy ? null : _loadBackups,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            if (_backups.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Text('暂无本地恢复点'),
              )
            else
              for (final backup in _backups)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.restore_page_outlined),
                  title: Text(_backupReasonLabel(backup.reason)),
                  subtitle: Text(
                    '${backup.createdAt.toLocal()} · schema v${backup.schemaVersion} · ${_formatBytes(backup.byteSize)}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Wrap(
                    children: [
                      IconButton(
                        tooltip: '恢复此版本',
                        onPressed: _busy ? null : () => _restoreBackup(backup),
                        icon: const Icon(Icons.settings_backup_restore),
                      ),
                      IconButton(
                        tooltip: '删除恢复点',
                        onPressed: _busy ? null : () => _deleteBackup(backup),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                ),
            const SizedBox(height: 24),
            _SectionLabel(label: '非敏感设置'),
            const SizedBox(height: 8),
            Text(
              '迁移界面和服务设置，但不包含设备身份、默认日历内部 ID、服务令牌或 AI Key。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : _exportSettings,
                  icon: const Icon(Icons.download_outlined),
                  label: const Text('导出设置'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : _importSettings,
                  icon: const Icon(Icons.upload_outlined),
                  label: const Text('导入设置'),
                ),
              ],
            ),
            const SizedBox(height: 24),
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
              '所有处理均在本机完成。',
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
                    onPressed: _busy || !_previewResult!.accepted
                        ? null
                        : _commitImport,
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
    });
  }

  Future<void> _loadBackups() async {
    try {
      final backups = await widget.controller.listLocalDatabaseBackups();
      if (mounted) setState(() => _backups = backups);
    } catch (_) {
      // Recovery points are unavailable for in-memory test repositories.
    }
  }

  Future<void> _createBackup() async {
    setState(() => _busy = true);
    try {
      final backup = await widget.controller.createLocalDatabaseBackup();
      await _loadBackups();
      if (mounted) _showStatus('恢复点已创建：${backup.fileName}');
    } catch (error) {
      if (mounted) _showStatus('创建恢复点失败：$error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreBackup(LocalDatabaseBackup backup) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复数据库？'),
        content: const Text('当前数据库会先自动创建恢复点，然后替换为所选版本。应用数据视图会立即刷新。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.settings_backup_restore),
            label: const Text('确认恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await widget.controller.restoreLocalDatabaseBackup(backup.path);
      await _loadBackups();
      if (mounted) _showStatus('数据库已恢复，恢复前状态也已保留');
    } catch (error) {
      if (mounted) _showStatus('恢复失败：$error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteBackup(LocalDatabaseBackup backup) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除恢复点？'),
        content: Text(backup.fileName),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await widget.controller.deleteLocalDatabaseBackup(backup.path);
      await _loadBackups();
      if (mounted) _showStatus('恢复点已删除');
    } catch (error) {
      if (mounted) _showStatus('删除恢复点失败：$error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportSettings() async {
    setState(() => _busy = true);
    try {
      final directory = await getApplicationSupportDirectory();
      final timestamp = _fileTimestamp();
      final file = File(
        '${directory.path}${Platform.pathSeparator}easycalendar-settings-$timestamp.json',
      );
      await file.writeAsString(
        widget.controller.exportPortableSettings(),
        flush: true,
      );
      if (mounted) _showStatus('非敏感设置已保存到：${file.path}');
    } catch (error) {
      if (mounted) _showStatus('设置导出失败：$error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importSettings() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    setState(() => _busy = true);
    try {
      await widget.controller.importPortableSettings(utf8.decode(bytes));
      if (mounted) _showStatus('非敏感设置已导入；设备身份、日历和密钥保持不变');
    } catch (error) {
      if (mounted) _showStatus('设置导入失败：$error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _fileTimestamp() => DateTime.now()
      .toUtc()
      .toIso8601String()
      .replaceAll(':', '-')
      .split('.')
      .first;

  static String _backupReasonLabel(LocalBackupReason reason) =>
      switch (reason) {
        LocalBackupReason.migration => '升级前自动恢复点',
        LocalBackupReason.manual => '手动恢复点',
        LocalBackupReason.preRestore => '恢复操作前的状态',
      };

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
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
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
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
        _showStatus('预览完成，发现 ${result.issues.length} 个问题', error: true);
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
        await widget.controller.commitLocalIcsImport(_previewContent!);
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

  Future<void> _exportIcs() async {
    setState(() => _busy = true);
    try {
      final ics = await widget.controller.exportLocalIcs();
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
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['ics'],
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    final content = utf8.decode(bytes);
    setState(() => _busy = true);
    try {
      final preview = await widget.controller.previewLocalIcsImport(content);
      if (!mounted) return;
      setState(() {
        _previewContent = content;
        _previewFormat = 'ics';
        _previewResult = preview;
      });
      if (preview.issues.isNotEmpty) {
        _showStatus('预览完成，发现 ${preview.issues.length} 个问题', error: true);
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
  Widget build(BuildContext context) =>
      Text(label, style: Theme.of(context).textTheme.titleSmall);
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
          Text(
            '格式：${result.format.toUpperCase()}',
            style: Theme.of(context).textTheme.titleSmall,
          ),
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
