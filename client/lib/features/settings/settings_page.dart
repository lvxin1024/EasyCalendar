import 'package:flutter/material.dart';

import '../../application/item_controller.dart';
import '../../config/app_config.dart';
import '../../domain/item.dart';

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
  late bool _syncEnabled;
  late bool _notificationsEnabled;

  @override
  void initState() {
    super.initState();
    final preferences = widget.controller.preferences;
    _apiUrlController = TextEditingController(text: preferences.apiUrl);
    _syncEnabled = preferences.syncEnabled;
    _notificationsEnabled = preferences.notificationsEnabled;
  }

  @override
  void dispose() {
    _apiUrlController.dispose();
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
              _SettingSwitch(
                icon: Icons.sync,
                title: '同步',
                subtitle: _syncEnabled ? '已启用' : '仅保存在此设备',
                value: _syncEnabled,
                onChanged: (value) => setState(() => _syncEnabled = value),
              ),
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
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('设置已保存')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$error')),
      );
    }
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
