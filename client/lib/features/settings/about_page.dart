import 'package:flutter/material.dart';

import '../../data/local_item_repository.dart';
import '../../update/app_update_service.dart';

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  late final AppUpdateService _updates;
  late final Future<AppBuildInfo> _buildInfo;
  ReleaseUpdate? _release;
  bool _checking = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _updates = AppUpdateService();
    _buildInfo = _updates.loadBuildInfo(
      schemaVersion: LocalItemRepository.schemaVersion,
    );
  }

  @override
  void dispose() {
    _updates.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('关于 EasyCalendar')),
    body: FutureBuilder<AppBuildInfo>(
      future: _buildInfo,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          if (snapshot.hasError) {
            return Center(child: Text('无法读取版本信息：${snapshot.error}'));
          }
          return const Center(child: CircularProgressIndicator());
        }
        final info = snapshot.data!;
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 72),
          children: [
            Text(
              'EasyCalendar',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            _InfoRow(label: '版本', value: info.version),
            _InfoRow(label: '构建号', value: info.buildNumber),
            _InfoRow(label: '平台', value: info.platform),
            _InfoRow(label: '数据 schema', value: 'v${info.schemaVersion}'),
            _InfoRow(label: '更新源', value: _updates.repository),
            const SizedBox(height: 24),
            FilledButton.tonalIcon(
              onPressed: _checking ? null : () => _check(info.version),
              icon: _checking
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.system_update_alt),
              label: Text(_checking ? '检查中' : '检查更新'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (_release != null) ...[
              const SizedBox(height: 24),
              Text(
                _release!.updateAvailable
                    ? '发现 ${_release!.latestVersion}'
                    : '当前已是最新版本',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Text(_release!.releaseName),
              if (_release!.notes.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                SelectableText(_release!.notes.trim()),
              ],
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _openRelease(_release!),
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('打开 Release 页面'),
                  ),
                  if (_release!.updateAvailable && _release!.assetUri != null)
                    FilledButton.icon(
                      onPressed: () => _openAsset(_release!),
                      icon: const Icon(Icons.download_outlined),
                      label: Text('下载 ${_release!.assetName}'),
                    ),
                ],
              ),
            ],
          ],
        );
      },
    ),
  );

  Future<void> _check(String currentVersion) async {
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final release = await _updates.checkForUpdate(currentVersion);
      if (mounted) setState(() => _release = release);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _openRelease(ReleaseUpdate release) async {
    if (!await _updates.openRelease(release) && mounted) {
      _showOpenError();
    }
  }

  Future<void> _openAsset(ReleaseUpdate release) async {
    if (!await _updates.openPlatformAsset(release) && mounted) {
      _showOpenError();
    }
  }

  void _showOpenError() {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('无法打开系统浏览器')));
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 112, child: Text(label)),
        Expanded(child: SelectableText(value)),
      ],
    ),
  );
}
