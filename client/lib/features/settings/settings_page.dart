import 'package:flutter/material.dart';

import '../../application/item_controller.dart';
import '../../config/app_config.dart';
import '../../domain/item.dart';
import '../../sync/sync_models.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.config,
    required this.controller,
  });

  final AppConfig config;
  final ItemController controller;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _apiUrlController;
  late final TextEditingController _tokenController;
  late bool _syncEnabled;
  late bool _notificationsEnabled;
  bool _obscureToken = true;

  @override
  void initState() {
    super.initState();
    final preferences = widget.controller.preferences;
    _apiUrlController = TextEditingController(text: preferences.apiUrl);
    _tokenController = TextEditingController();
    _syncEnabled = preferences.syncEnabled;
    _notificationsEnabled = preferences.notificationsEnabled;
  }

  @override
  void dispose() {
    _apiUrlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
        child: Text('设置', style: Theme.of(context).textTheme.headlineSmall),
      ),
      Expanded(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 96),
            children: [
              _SectionLabel(label: '连接'),
              TextFormField(
                controller: _apiUrlController,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'API 地址',
                  prefixIcon: Icon(Icons.link),
                ),
                validator: _validateUrl,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _tokenController,
                obscureText: _obscureToken,
                decoration: InputDecoration(
                  labelText:
                      widget.controller.syncCoordinator?.tokenConfigured == true
                      ? '访问令牌（已保存）'
                      : '访问令牌',
                  prefixIcon: const Icon(Icons.key_outlined),
                  suffixIcon: IconButton(
                    tooltip: _obscureToken ? '显示令牌' : '隐藏令牌',
                    onPressed: () =>
                        setState(() => _obscureToken = !_obscureToken),
                    icon: Icon(
                      _obscureToken
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                  ),
                ),
                validator: (value) {
                  final token = value?.trim() ?? '';
                  if (token.isNotEmpty && token.length < 32) {
                    return '令牌至少需要 32 个字符';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 10),
              _SettingSwitch(
                icon: Icons.sync,
                title: '同步',
                subtitle: _syncEnabled ? '已启用' : '仅保存在此设备',
                value: _syncEnabled,
                onChanged: (value) => setState(() => _syncEnabled = value),
              ),
              if (_syncEnabled) ...[
                _InfoRow(icon: _syncIcon, label: '同步状态', value: _syncStatus),
                const SizedBox(height: 8),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  children: [
                    if (widget.controller.syncCoordinator?.tokenConfigured ==
                        true)
                      TextButton.icon(
                        onPressed: widget.controller.mutating
                            ? null
                            : _clearToken,
                        icon: const Icon(Icons.key_off_outlined),
                        label: const Text('清除令牌'),
                      ),
                    OutlinedButton.icon(
                      onPressed:
                          widget.controller.syncCoordinator?.snapshot.phase ==
                              SyncPhase.syncing
                          ? null
                          : _syncNow,
                      icon: const Icon(Icons.sync),
                      label: const Text('立即同步'),
                    ),
                    TextButton.icon(
                      onPressed: _showConflictHistory,
                      icon: const Icon(Icons.history_outlined),
                      label: const Text('冲突历史'),
                    ),
                  ],
                ),
              ],
              _SettingSwitch(
                icon: Icons.notifications_outlined,
                title: '通知',
                subtitle: _notificationsEnabled ? '已启用' : '已关闭',
                value: _notificationsEnabled,
                onChanged: (value) =>
                    setState(() => _notificationsEnabled = value),
              ),
              const SizedBox(height: 24),
              _SectionLabel(label: '本地环境'),
              _InfoRow(
                icon: Icons.language,
                label: '语言',
                value: widget.config.locale.toLanguageTag(),
              ),
              _InfoRow(
                icon: Icons.schedule,
                label: '时区',
                value: widget.config.timezone,
              ),
              _InfoRow(
                icon: Icons.folder_outlined,
                label: '默认 Collection',
                value: widget.config.defaultCollectionName,
              ),
              _InfoRow(
                icon: Icons.storage_outlined,
                label: '本地数据库',
                value: widget.controller.databasePath ?? '尚未初始化',
              ),
              const SizedBox(height: 20),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: widget.controller.mutating ? null : _save,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('保存设置'),
                ),
              ),
            ],
          ),
        ),
      ),
    ],
  );

  String? _validateUrl(String? raw) {
    final value = raw?.trim() ?? '';
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return '请输入有效的 HTTP(S) 地址';
    }
    return null;
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    try {
      await widget.controller.savePreferences(
        ClientPreferences(
          apiUrl: _apiUrlController.text.trim(),
          syncEnabled: _syncEnabled,
          notificationsEnabled: _notificationsEnabled,
        ),
      );
      if (_tokenController.text.trim().isNotEmpty) {
        await widget.controller.saveSyncToken(_tokenController.text);
        _tokenController.clear();
      }
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('设置已保存')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保存失败：$error')));
    }
  }

  IconData get _syncIcon =>
      switch (widget.controller.syncCoordinator?.snapshot.phase) {
        SyncPhase.syncing => Icons.sync,
        SyncPhase.backoff => Icons.schedule,
        SyncPhase.needsAuthentication => Icons.key_off_outlined,
        SyncPhase.failed => Icons.error_outline,
        _ => Icons.cloud_done_outlined,
      };

  String get _syncStatus {
    final snapshot = widget.controller.syncCoordinator?.snapshot;
    return switch (snapshot?.phase) {
      SyncPhase.disabled => '已关闭',
      SyncPhase.idle => snapshot?.lastSyncedAt == null ? '等待同步' : '已同步',
      SyncPhase.syncing => '同步中',
      SyncPhase.backoff => '等待重试',
      SyncPhase.needsAuthentication => '需要访问令牌',
      SyncPhase.failed => snapshot?.message ?? '同步失败',
      null => '不可用',
    };
  }

  Future<void> _clearToken() async {
    await widget.controller.clearSyncToken();
    if (mounted) setState(() {});
  }

  Future<void> _syncNow() async {
    try {
      await widget.controller.synchronizeNow();
      if (mounted) setState(() {});
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('同步失败：$error')));
    }
  }

  Future<void> _showConflictHistory() async {
    final conflicts = await widget.controller.loadSyncConflictHistory();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('冲突历史'),
        content: SizedBox(
          width: 520,
          child: conflicts.isEmpty
              ? const Text('暂无冲突记录')
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: conflicts.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final conflict = conflicts[index];
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.compare_arrows_outlined),
                      title: Text(
                        '${conflict.winner.entityType} · '
                        '${conflict.winner.entityId}',
                      ),
                      subtitle: Text(
                        '保留 v${conflict.winner.version} '
                        '(${conflict.winner.changeId})\n'
                        '覆盖 v${conflict.loser.version} '
                        '(${conflict.loser.changeId})',
                      ),
                      isThreeLine: true,
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(label, style: Theme.of(context).textTheme.titleSmall),
  );
}

class _SettingSwitch extends StatelessWidget {
  const _SettingSwitch({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(bottom: BorderSide(color: Color(0xFFE4E7EC))),
    ),
    child: SwitchListTile(
      secondary: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: onChanged,
    ),
  );
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(bottom: BorderSide(color: Color(0xFFE4E7EC))),
    ),
    child: ListTile(
      leading: Icon(icon),
      title: Text(label),
      subtitle: Text(value, maxLines: 2, overflow: TextOverflow.ellipsis),
    ),
  );
}
