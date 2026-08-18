import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../ai/ai_provider.dart';
import '../../application/item_controller.dart';
import '../../config/app_config.dart';
import '../../data/service_probe_client.dart';
import '../../device/device_identity.dart';
import '../../domain/item.dart';
import '../../sync/sync_models.dart';
import '../../utils/tag_colors.dart';
import '../../widgets/tag_filter_bar.dart';
import '../recycle_bin/recycle_bin_page.dart';
import '../transfer/transfer_page.dart';

const _localeOptions = <String, String>{
  'system': '跟随系统',
  'zh-CN': '简体中文',
  'en': 'English',
};
const _firstDayOfWeekOptions = <int, String>{
  0: '跟随语言',
  1: '周一',
  2: '周二',
  3: '周三',
  4: '周四',
  5: '周五',
  6: '周六',
  7: '周日',
};
const _clockFormatOptions = <ClockFormat, String>{
  ClockFormat.system: '跟随系统',
  ClockFormat.hour12: '12 小时制',
  ClockFormat.hour24: '24 小时制',
};

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
  late final TextEditingController _featureApiUrlController;
  late final TextEditingController _featureTokenController;
  late final TextEditingController _deviceNameController;
  late final TextEditingController _deviceIdController;
  late final TextEditingController _collectionIdController;
  late final TextEditingController _collectionNameController;
  late final TextEditingController _tokenController;
  late bool _syncEnabled;
  late bool _notificationsEnabled;
  late double _windowOpacity;
  late bool _windowAlwaysOnTop;
  late bool _assistantEnabled;
  late String _timezone;
  late String _localeName;
  late int _firstDayOfWeek;
  late ClockFormat _clockFormat;
  late List<AiProviderConfig> _aiProviders;
  late Map<String, int> _tagColors;
  bool _obscureToken = true;
  bool _obscureFeatureToken = true;
  bool _testingSyncService = false;
  bool _testingFeatureService = false;
  String? _syncProbeStatus;
  String? _featureProbeStatus;
  bool _syncProbeFailed = false;
  bool _featureProbeFailed = false;

  @override
  void initState() {
    super.initState();
    final preferences = widget.controller.preferences;
    _apiUrlController = TextEditingController(text: preferences.apiUrl);
    _featureApiUrlController = TextEditingController(
      text: preferences.featureApiUrl,
    );
    _featureTokenController = TextEditingController();
    _deviceNameController = TextEditingController(text: preferences.deviceName);
    _deviceIdController = TextEditingController(text: preferences.deviceId);
    _collectionIdController = TextEditingController(
      text: preferences.defaultCollectionId,
    );
    _collectionNameController = TextEditingController(
      text: preferences.defaultCollectionName,
    );
    _tokenController = TextEditingController();
    _syncEnabled = preferences.syncEnabled;
    _notificationsEnabled = preferences.notificationsEnabled;
    _windowOpacity = preferences.windowOpacity;
    _windowAlwaysOnTop = preferences.windowAlwaysOnTop;
    _assistantEnabled = preferences.assistantEnabled;
    _timezone = preferences.timezone;
    _localeName = preferences.localeName;
    _firstDayOfWeek = preferences.firstDayOfWeek;
    _clockFormat = preferences.clockFormat;
    _aiProviders = [...preferences.aiProviders];
    _tagColors = {...preferences.tagColors};
    widget.controller.desktopWindowController?.addListener(_windowChanged);
    unawaited(_refreshAiProviderKeys());
  }

  @override
  void dispose() {
    _apiUrlController.dispose();
    _featureApiUrlController.dispose();
    _featureTokenController.dispose();
    _deviceNameController.dispose();
    _deviceIdController.dispose();
    _collectionIdController.dispose();
    _collectionNameController.dispose();
    _tokenController.dispose();
    widget.controller.desktopWindowController?.removeListener(_windowChanged);
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
                  labelText: '同步服务地址',
                  helperText: '多设备同步请填写 Cloudflare Worker 的 HTTPS 地址',
                  prefixIcon: Icon(Icons.link),
                ),
                validator: _validateUrl,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _featureApiUrlController,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: '功能服务地址',
                  helperText: '兼容 Python Core API；安装包本地功能不依赖此地址',
                  prefixIcon: Icon(Icons.hub_outlined),
                ),
                validator: _validateUrl,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _featureTokenController,
                obscureText: _obscureFeatureToken,
                decoration: InputDecoration(
                  labelText: widget.controller.featureTokenConfigured
                      ? '功能服务令牌（已保存，可选）'
                      : '功能服务令牌（可选）',
                  helperText: 'Python Core 未启用鉴权时留空',
                  prefixIcon: const Icon(Icons.vpn_key_outlined),
                  suffixIcon: Wrap(
                    spacing: 0,
                    children: [
                      if (widget.controller.featureTokenConfigured)
                        IconButton(
                          tooltip: '清除功能服务令牌',
                          onPressed: _clearFeatureToken,
                          icon: const Icon(Icons.key_off_outlined),
                        ),
                      IconButton(
                        tooltip: _obscureFeatureToken ? '显示令牌' : '隐藏令牌',
                        onPressed: () => setState(
                          () => _obscureFeatureToken = !_obscureFeatureToken,
                        ),
                        icon: Icon(
                          _obscureFeatureToken
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _deviceNameController,
                decoration: const InputDecoration(
                  labelText: '设备名称',
                  helperText: '用于识别这台设备，可以随时修改',
                  prefixIcon: Icon(Icons.devices_outlined),
                ),
                maxLength: 80,
                validator: _validateRequired,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _collectionNameController,
                decoration: const InputDecoration(
                  labelText: '默认 Collection 名称',
                  prefixIcon: Icon(Icons.label_outline),
                ),
                validator: _validateRequired,
              ),
              const SizedBox(height: 10),
              ExpansionTile(
                tilePadding: const EdgeInsets.symmetric(horizontal: 12),
                childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                leading: const Icon(Icons.tune),
                title: const Text('高级连接设置'),
                subtitle: const Text('设备和 Collection 的内部标识'),
                children: [
                  TextFormField(
                    controller: _deviceIdController,
                    readOnly: true,
                    decoration: InputDecoration(
                      labelText: '设备 ID（自动管理）',
                      helperText: '重建设备身份不会改写尚未同步的旧变更',
                      prefixIcon: const Icon(Icons.fingerprint),
                      suffixIcon: Wrap(
                        spacing: 0,
                        children: [
                          IconButton(
                            tooltip: '复制设备 ID',
                            onPressed: _copyDeviceId,
                            icon: const Icon(Icons.copy_outlined),
                          ),
                          IconButton(
                            tooltip: '重建设备身份',
                            onPressed: _regenerateDeviceIdentity,
                            icon: const Icon(Icons.refresh),
                          ),
                        ],
                      ),
                    ),
                    validator: _validateDeviceId,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _collectionIdController,
                    decoration: const InputDecoration(
                      labelText: '默认 Collection ID',
                      helperText: '同一同步实例的设备应使用相同 ID；修改不会迁移旧数据',
                      prefixIcon: Icon(Icons.folder_outlined),
                    ),
                    validator: _validateRequired,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _tokenController,
                obscureText: _obscureToken,
                decoration: InputDecoration(
                  labelText:
                      widget.controller.syncCoordinator?.tokenConfigured == true
                      ? '同步服务令牌（已保存）'
                      : '同步服务令牌',
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
              _ServiceProbeRow(
                icon: Icons.cloud_sync_outlined,
                label: '同步服务',
                status: _syncProbeStatus,
                failed: _syncProbeFailed,
                testing: _testingSyncService,
                onPressed: () => _testService(ServiceKind.sync),
              ),
              _ServiceProbeRow(
                icon: Icons.hub_outlined,
                label: '功能服务',
                status: _featureProbeStatus,
                failed: _featureProbeFailed,
                testing: _testingFeatureService,
                onPressed: () => _testService(ServiceKind.feature),
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
                subtitle: _notificationsEnabled
                    ? widget.controller.notificationService?.statusText ?? '已启用'
                    : '已关闭',
                value: _notificationsEnabled,
                onChanged: (value) async {
                  setState(() => _notificationsEnabled = value);
                  if (value) {
                    await widget.controller.notificationService?.initialize();
                    await widget.controller.notificationService?.reconcileAll(
                      widget.controller.items,
                    );
                    setState(() {});
                  }
                },
              ),
              _AiProviderSection(
                enabled: _assistantEnabled,
                providers: _aiProviders,
                onEnabledChanged: (value) async {
                  setState(() => _assistantEnabled = value);
                  await _saveAiPreferences();
                },
                onAdd: () => _showProviderEditor(),
                onImport: _importProvider,
                onEdit: _showProviderEditor,
                onDelete: _deleteProvider,
                onToggle: _toggleProvider,
                onTest: _testProvider,
              ),
              _CollectionSection(
                collections: widget.controller.collections,
                onAdd: () => _showCollectionEditor(),
                onEdit: _showCollectionEditor,
                onDelete: _deleteCollection,
              ),
              _TagColorSection(
                tags: tagsFromItems(widget.controller.items),
                colors: _tagColors,
                onChanged: _setTagColor,
              ),
              if (widget.controller.desktopWindowController?.available == true)
                _DesktopWindowSection(
                  opacity: _windowOpacity,
                  alwaysOnTop: _windowAlwaysOnTop,
                  locked: widget
                      .controller
                      .desktopWindowController!
                      .interactionLocked,
                  onOpacityChanged: _setWindowOpacity,
                  onAlwaysOnTopChanged: _setAlwaysOnTop,
                  onLockedChanged: _setInteractionLocked,
                ),
              const SizedBox(height: 24),
              _SectionLabel(label: '本地环境'),
              DropdownButtonFormField<String>(
                initialValue: _localeOptions.containsKey(_localeName)
                    ? _localeName
                    : 'system',
                decoration: const InputDecoration(
                  labelText: '语言',
                  prefixIcon: Icon(Icons.language),
                ),
                items: _localeOptions.entries
                    .map(
                      (entry) => DropdownMenuItem(
                        value: entry.key,
                        child: Text(entry.value),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (value) {
                  if (value != null) setState(() => _localeName = value);
                },
              ),
              const SizedBox(height: 10),
              TextFormField(
                initialValue: _timezone,
                decoration: const InputDecoration(
                  labelText: '时区',
                  helperText: '填写 system 跟随系统，或填写 IANA 时区（如 Asia/Shanghai）',
                  prefixIcon: Icon(Icons.schedule),
                ),
                validator: _validateTimezone,
                onChanged: (value) => _timezone = value.trim(),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<int>(
                initialValue:
                    _firstDayOfWeekOptions.containsKey(_firstDayOfWeek)
                    ? _firstDayOfWeek
                    : 0,
                decoration: const InputDecoration(
                  labelText: '每周起始日',
                  prefixIcon: Icon(Icons.date_range_outlined),
                ),
                items: _firstDayOfWeekOptions.entries
                    .map(
                      (entry) => DropdownMenuItem(
                        value: entry.key,
                        child: Text(entry.value),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (value) {
                  if (value != null) setState(() => _firstDayOfWeek = value);
                },
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<ClockFormat>(
                initialValue: _clockFormat,
                decoration: const InputDecoration(
                  labelText: '时间显示',
                  prefixIcon: Icon(Icons.access_time_outlined),
                ),
                items: _clockFormatOptions.entries
                    .map(
                      (entry) => DropdownMenuItem(
                        value: entry.key,
                        child: Text(entry.value),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (value) {
                  if (value != null) setState(() => _clockFormat = value);
                },
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
              const SizedBox(height: 24),
              _SectionLabel(label: '数据管理'),
              ListTile(
                leading: const Icon(Icons.file_upload_outlined),
                title: const Text('导入 / 导出'),
                subtitle: const Text('JSON 备份恢复、ICS 日历文件导入导出'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => Scaffold(
                        appBar: AppBar(title: const Text('导入导出')),
                        body: TransferPage(controller: widget.controller),
                      ),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_sweep_outlined),
                title: const Text('回收站'),
                subtitle: const Text('查看和恢复已删除的事项'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => Scaffold(
                        appBar: AppBar(title: const Text('回收站')),
                        body: RecycleBinPage(controller: widget.controller),
                      ),
                    ),
                  );
                },
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

  String? _validateRequired(String? raw) =>
      raw?.trim().isNotEmpty == true ? null : '不能为空';

  String? _validateTimezone(String? raw) {
    final value = raw?.trim() ?? '';
    if (value == 'system') return null;
    try {
      tz.getLocation(value);
      return null;
    } catch (_) {
      return '请输入 system 或有效的 IANA 时区';
    }
  }

  String? _validateDeviceId(String? raw) {
    final value = raw?.trim() ?? '';
    if (!DeviceIdentity.isValid(value)) {
      return '请输入 2-128 位设备 ID（字母、数字、点、下划线或连字符）';
    }
    return null;
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    try {
      await widget.controller.savePreferences(
        ClientPreferences(
          apiUrl: _apiUrlController.text.trim(),
          featureApiUrl: _featureApiUrlController.text.trim(),
          timezone: _timezone,
          localeName: _localeName,
          firstDayOfWeek: _firstDayOfWeek,
          clockFormat: _clockFormat,
          deviceId: _deviceIdController.text.trim(),
          deviceName: _deviceNameController.text.trim(),
          defaultCollectionId: _collectionIdController.text.trim(),
          defaultCollectionName: _collectionNameController.text.trim(),
          syncEnabled: _syncEnabled,
          notificationsEnabled: _notificationsEnabled,
          windowOpacity: _windowOpacity,
          windowAlwaysOnTop: _windowAlwaysOnTop,
          assistantEnabled: _assistantEnabled,
          aiProviders: _aiProviders,
          tagColors: _tagColors,
        ),
      );
      if (_tokenController.text.trim().isNotEmpty) {
        await widget.controller.saveSyncToken(_tokenController.text);
        _tokenController.clear();
      }
      if (_featureTokenController.text.trim().isNotEmpty) {
        await widget.controller.saveFeatureToken(_featureTokenController.text);
        _featureTokenController.clear();
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

  Future<void> _refreshAiProviderKeys() async {
    final providers = await widget.controller.refreshAiProviderKeyStatus();
    if (mounted) setState(() => _aiProviders = providers);
  }

  Future<void> _copyDeviceId() async {
    await Clipboard.setData(ClipboardData(text: _deviceIdController.text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('设备 ID 已复制')));
  }

  Future<void> _regenerateDeviceIdentity() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重建设备身份？'),
        content: const Text(
          '只有复制安装、设备身份冲突或排查同步问题时才需要重建。'
          '尚未同步的旧变更会继续使用旧 ID 上传，新变更将使用新 ID。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('重建'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final preferences = await widget.controller.regenerateDeviceIdentity();
      if (!mounted) return;
      setState(() => _deviceIdController.text = preferences.deviceId);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已生成新的设备 ID')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('重建设备身份失败：$error')));
    }
  }

  Future<void> _saveAiPreferences() async {
    await widget.controller.savePreferences(
      widget.controller.preferences.copyWith(
        assistantEnabled: _assistantEnabled,
        aiProviders: _aiProviders,
      ),
    );
  }

  void _setTagColor(String tag, Color? color) {
    setState(() {
      if (color == null) {
        _tagColors.remove(tag);
      } else {
        _tagColors[tag] = color.toARGB32();
      }
    });
    unawaited(
      widget.controller.savePreferences(
        widget.controller.preferences.copyWith(tagColors: _tagColors),
      ),
    );
  }

  Future<void> _showCollectionEditor([CalendarCollection? current]) async {
    final result = await showDialog<_CollectionDraft>(
      context: context,
      builder: (_) => _CollectionDialog(current: current),
    );
    if (result == null) return;
    try {
      if (current == null) {
        await widget.controller.createCollection(
          name: result.name,
          color: result.color.toARGB32(),
        );
      } else {
        await widget.controller.updateCollection(
          current,
          name: result.name,
          color: result.color.toARGB32(),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Collection 保存失败：$error')));
      }
    }
  }

  Future<void> _deleteCollection(CalendarCollection collection) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除 Collection'),
        content: Text('确定删除“${collection.name}”吗？'),
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
    try {
      await widget.controller.deleteCollection(collection);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Collection 删除失败：$error')));
      }
    }
  }

  Future<void> _showProviderEditor([AiProviderConfig? current]) async {
    final imported = await showDialog<AiProviderImport>(
      context: context,
      builder: (_) => _ProviderDialog(current: current),
    );
    if (imported == null) return;
    try {
      await widget.controller.saveAiProvider(
        imported.config,
        apiKey: imported.apiKey,
      );
      final providers = await widget.controller.refreshAiProviderKeyStatus();
      if (mounted) setState(() => _aiProviders = providers);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Provider 保存失败：$error')));
      }
    }
  }

  Future<void> _importProvider() => _showProviderEditor();

  Future<void> _deleteProvider(AiProviderConfig provider) async {
    await widget.controller.deleteAiProvider(provider.id);
    if (mounted) {
      setState(
        () => _aiProviders.removeWhere((item) => item.id == provider.id),
      );
    }
  }

  Future<void> _toggleProvider(AiProviderConfig provider, bool enabled) async {
    await widget.controller.saveAiProvider(provider.copyWith(enabled: enabled));
    if (mounted) {
      setState(() {
        final index = _aiProviders.indexWhere((item) => item.id == provider.id);
        if (index >= 0) {
          _aiProviders[index] = provider.copyWith(enabled: enabled);
        }
      });
    }
  }

  Future<void> _testProvider(AiProviderConfig provider) async {
    try {
      await widget.controller.testAiProvider(provider);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('连接成功')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('连接失败：$error')));
      }
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

  Future<void> _clearFeatureToken() async {
    await widget.controller.clearFeatureToken();
    if (mounted) setState(() {});
  }

  Future<void> _testService(ServiceKind kind) async {
    final isSync = kind == ServiceKind.sync;
    final url = isSync
        ? _apiUrlController.text.trim()
        : _featureApiUrlController.text.trim();
    final validationError = _validateUrl(url);
    if (validationError != null) {
      setState(() {
        if (isSync) {
          _syncProbeStatus = validationError;
          _syncProbeFailed = true;
        } else {
          _featureProbeStatus = validationError;
          _featureProbeFailed = true;
        }
      });
      return;
    }
    setState(() {
      if (isSync) {
        _testingSyncService = true;
        _syncProbeStatus = null;
      } else {
        _testingFeatureService = true;
        _featureProbeStatus = null;
      }
    });

    var failed = false;
    late String status;
    try {
      final result = await widget.controller.testServiceConnection(
        kind: kind,
        serverUrl: url,
        pendingToken: isSync
            ? _tokenController.text
            : _featureTokenController.text,
      );
      final authentication = result.capabilities.authenticationRequired
          ? '鉴权通过'
          : '无需鉴权';
      if (isSync) {
        status = '连接成功 · v${result.serviceVersion} · $authentication';
      } else {
        final features = <String>[
          if (result.capabilities.supports('ics_subscriptions')) '网址订阅',
          if (result.capabilities.supports('ics_transfer')) 'ICS 兼容 API',
        ].join('、');
        status = '连接成功 · $features · $authentication';
      }
    } on ServiceProbeException catch (error) {
      failed = true;
      status = error.message;
    } catch (error) {
      failed = true;
      status = '连接检测失败：$error';
    }
    if (!mounted) return;
    setState(() {
      if (isSync) {
        _testingSyncService = false;
        _syncProbeStatus = status;
        _syncProbeFailed = failed;
      } else {
        _testingFeatureService = false;
        _featureProbeStatus = status;
        _featureProbeFailed = failed;
      }
    });
  }

  void _windowChanged() {
    if (mounted) setState(() {});
  }

  void _setWindowOpacity(double value) {
    setState(() => _windowOpacity = value);
    unawaited(widget.controller.desktopWindowController?.setOpacity(value));
  }

  void _setAlwaysOnTop(bool value) {
    setState(() => _windowAlwaysOnTop = value);
    unawaited(widget.controller.desktopWindowController?.setAlwaysOnTop(value));
  }

  Future<void> _setInteractionLocked(bool value) async {
    if (!value) {
      await widget.controller.desktopWindowController?.setInteractionLocked(
        false,
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('锁定窗口交互？'),
        content: const Text(
          '锁定后鼠标会穿透窗口。macOS 请从 Dock 右键菜单解锁，Windows 请按 Ctrl+Alt+L。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.lock_outline),
            label: const Text('锁定'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.controller.desktopWindowController?.setInteractionLocked(
        true,
      );
    }
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

class _ServiceProbeRow extends StatelessWidget {
  const _ServiceProbeRow({
    required this.icon,
    required this.label,
    required this.status,
    required this.failed,
    required this.testing,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final String? status;
  final bool failed;
  final bool testing;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Icon(
          status == null
              ? icon
              : failed
              ? Icons.error_outline
              : Icons.check_circle_outline,
          color: status == null
              ? null
              : failed
              ? Theme.of(context).colorScheme.error
              : Colors.green.shade700,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            status ?? '$label尚未检测',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: testing ? null : onPressed,
          icon: testing
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.network_check, size: 18),
          label: Text(testing ? '检测中' : '测试连接'),
        ),
      ],
    ),
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

class _DesktopWindowSection extends StatelessWidget {
  const _DesktopWindowSection({
    required this.opacity,
    required this.alwaysOnTop,
    required this.locked,
    required this.onOpacityChanged,
    required this.onAlwaysOnTopChanged,
    required this.onLockedChanged,
  });

  final double opacity;
  final bool alwaysOnTop;
  final bool locked;
  final ValueChanged<double> onOpacityChanged;
  final ValueChanged<bool> onAlwaysOnTopChanged;
  final Future<void> Function(bool) onLockedChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: 24),
      const _SectionLabel(label: '桌面窗口'),
      DecoratedBox(
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: Color(0xFFE4E7EC))),
        ),
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.opacity_outlined),
              title: const Text('窗口透明度'),
              subtitle: Text('${(opacity * 100).round()}%'),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Slider(
                value: opacity,
                min: 0.2,
                max: 1,
                divisions: 16,
                label: '${(opacity * 100).round()}%',
                onChanged: onOpacityChanged,
              ),
            ),
            const Divider(height: 1),
            SwitchListTile(
              secondary: const Icon(Icons.push_pin_outlined),
              title: const Text('始终置顶'),
              subtitle: const Text('窗口保持在其他窗口上方'),
              value: alwaysOnTop,
              onChanged: onAlwaysOnTopChanged,
            ),
            const Divider(height: 1),
            SwitchListTile(
              secondary: const Icon(Icons.mouse_outlined),
              title: const Text('锁定交互'),
              subtitle: const Text('鼠标点击和滚动穿透到下一层窗口'),
              value: locked,
              onChanged: (value) => unawaited(onLockedChanged(value)),
            ),
          ],
        ),
      ),
    ],
  );
}

class _CollectionSection extends StatelessWidget {
  const _CollectionSection({
    required this.collections,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
  });

  final List<CalendarCollection> collections;
  final VoidCallback onAdd;
  final ValueChanged<CalendarCollection> onEdit;
  final ValueChanged<CalendarCollection> onDelete;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: 24),
      const _SectionLabel(label: 'Collections'),
      for (final collection in collections)
        ListTile(
          leading: CircleAvatar(
            radius: 10,
            backgroundColor: collection.color == null
                ? Theme.of(context).colorScheme.primary
                : Color(collection.color!),
          ),
          title: Text(collection.name),
          subtitle: Text(
            collection.readonly ? '只读订阅 Collection' : '本地 Collection',
          ),
          trailing: collection.readonly
              ? const Icon(Icons.lock_outline, size: 20)
              : Wrap(
                  spacing: 0,
                  children: [
                    IconButton(
                      tooltip: '编辑 Collection',
                      onPressed: () => onEdit(collection),
                      icon: const Icon(Icons.edit_outlined),
                    ),
                    IconButton(
                      tooltip: '删除 Collection',
                      onPressed: () => onDelete(collection),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                ),
        ),
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Align(
          alignment: Alignment.centerRight,
          child: FilledButton.tonalIcon(
            onPressed: onAdd,
            icon: const Icon(Icons.create_new_folder_outlined),
            label: const Text('新建 Collection'),
          ),
        ),
      ),
    ],
  );
}

class _CollectionDraft {
  const _CollectionDraft({required this.name, required this.color});

  final String name;
  final Color color;
}

class _CollectionDialog extends StatefulWidget {
  const _CollectionDialog({this.current});

  final CalendarCollection? current;

  @override
  State<_CollectionDialog> createState() => _CollectionDialogState();
}

class _CollectionDialogState extends State<_CollectionDialog> {
  late final TextEditingController _name;
  late Color _color;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.current?.name ?? '');
    _color = widget.current?.color == null
        ? tagPalette.first
        : Color(widget.current!.color!);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.current == null ? '新建 Collection' : '编辑 Collection'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(labelText: '名称'),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            children: [
              for (final color in tagPalette)
                IconButton(
                  tooltip: '选择颜色',
                  onPressed: () => setState(() => _color = color),
                  icon: CircleAvatar(
                    radius: 12,
                    backgroundColor: color,
                    child: _color == color
                        ? Icon(Icons.check, size: 16, color: onTagColor(color))
                        : null,
                  ),
                ),
            ],
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          final name = _name.text.trim();
          if (name.isEmpty) return;
          Navigator.pop(context, _CollectionDraft(name: name, color: _color));
        },
        child: const Text('保存'),
      ),
    ],
  );
}

class _TagColorSection extends StatelessWidget {
  const _TagColorSection({
    required this.tags,
    required this.colors,
    required this.onChanged,
  });

  final List<String> tags;
  final Map<String, int> colors;
  final void Function(String tag, Color? color) onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: 24),
      const _SectionLabel(label: '标签颜色'),
      if (tags.isEmpty)
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text('创建事项后可以在这里分配标签颜色'),
        ),
      for (final tag in tags)
        ListTile(
          leading: CircleAvatar(
            radius: 10,
            backgroundColor: colorForTag(tag, colors),
          ),
          title: Text(tag),
          subtitle: Text(colors.containsKey(tag) ? '已自定义' : '使用默认颜色'),
          trailing: Wrap(
            spacing: 2,
            children: [
              PopupMenuButton<Color>(
                tooltip: '选择颜色',
                icon: const Icon(Icons.palette_outlined),
                onSelected: (color) => onChanged(tag, color),
                itemBuilder: (context) => [
                  for (final color in tagPalette)
                    PopupMenuItem(
                      value: color,
                      child: Row(
                        children: [
                          CircleAvatar(radius: 8, backgroundColor: color),
                          const SizedBox(width: 10),
                          Text(
                            '#${color.toARGB32().toRadixString(16).substring(2).toUpperCase()}',
                          ),
                        ],
                      ),
                    ),
                ],
              ),
              if (colors.containsKey(tag))
                IconButton(
                  tooltip: '恢复默认颜色',
                  onPressed: () => onChanged(tag, null),
                  icon: const Icon(Icons.restart_alt),
                ),
            ],
          ),
        ),
    ],
  );
}

class _AiProviderSection extends StatelessWidget {
  const _AiProviderSection({
    required this.enabled,
    required this.providers,
    required this.onEnabledChanged,
    required this.onAdd,
    required this.onImport,
    required this.onEdit,
    required this.onDelete,
    required this.onToggle,
    required this.onTest,
  });

  final bool enabled;
  final List<AiProviderConfig> providers;
  final ValueChanged<bool> onEnabledChanged;
  final VoidCallback onAdd;
  final VoidCallback onImport;
  final ValueChanged<AiProviderConfig> onEdit;
  final ValueChanged<AiProviderConfig> onDelete;
  final void Function(AiProviderConfig, bool) onToggle;
  final ValueChanged<AiProviderConfig> onTest;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: 24),
      const _SectionLabel(label: 'AI 助手'),
      _SettingSwitch(
        icon: Icons.auto_awesome_outlined,
        title: '启用 AI 助手',
        subtitle: enabled ? '候选项仍需确认后才会写入日程' : '使用本地规则解析器',
        value: enabled,
        onChanged: onEnabledChanged,
      ),
      if (providers.isEmpty)
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text('尚未配置 Provider'),
        ),
      for (final provider in providers)
        DecoratedBox(
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: Color(0xFFE4E7EC))),
          ),
          child: ListTile(
            leading: Icon(
              provider.kind == AiProviderKind.ollama
                  ? Icons.memory_outlined
                  : Icons.cloud_outlined,
            ),
            title: Text(provider.name),
            subtitle: Text(
              '${provider.model} · ${provider.keyConfigured ? '密钥已配置' : '未配置密钥'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Wrap(
              spacing: 0,
              children: [
                IconButton(
                  tooltip: '测试连接',
                  icon: const Icon(Icons.network_check_outlined),
                  onPressed: () => onTest(provider),
                ),
                IconButton(
                  tooltip: '编辑 Provider',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => onEdit(provider),
                ),
                Switch(
                  value: provider.enabled,
                  onChanged: (value) => onToggle(provider, value),
                ),
                IconButton(
                  tooltip: '删除 Provider',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => onDelete(provider),
                ),
              ],
            ),
          ),
        ),
      Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: onImport,
              icon: const Icon(Icons.file_upload_outlined),
              label: const Text('导入配置'),
            ),
            FilledButton.tonalIcon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('添加 Provider'),
            ),
          ],
        ),
      ),
    ],
  );
}

class _ProviderDialog extends StatefulWidget {
  const _ProviderDialog({this.current});

  final AiProviderConfig? current;

  @override
  State<_ProviderDialog> createState() => _ProviderDialogState();
}

class _ProviderDialogState extends State<_ProviderDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _model;
  late final TextEditingController _apiKey;
  late AiProviderKind _kind;
  bool _importMode = false;
  final _importController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final current = widget.current;
    _name = TextEditingController(text: current?.name ?? '我的 AI');
    _baseUrl = TextEditingController(
      text: current?.baseUrl ?? 'http://localhost:11434',
    );
    _model = TextEditingController(text: current?.model ?? '');
    _apiKey = TextEditingController();
    _kind = current?.kind ?? AiProviderKind.ollama;
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _model.dispose();
    _apiKey.dispose();
    _importController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.current == null ? '添加 Provider' : '编辑 Provider'),
    content: SizedBox(
      width: 460,
      child: _importMode ? _buildImport() : _buildForm(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      TextButton(
        onPressed: () => setState(() => _importMode = !_importMode),
        child: Text(_importMode ? '手动填写' : '粘贴 JSON'),
      ),
      FilledButton(onPressed: _submit, child: const Text('保存')),
    ],
  );

  Widget _buildForm() => Form(
    key: _formKey,
    child: ListView(
      shrinkWrap: true,
      children: [
        DropdownButtonFormField<AiProviderKind>(
          initialValue: _kind,
          decoration: const InputDecoration(labelText: '类型'),
          items: const [
            DropdownMenuItem(
              value: AiProviderKind.ollama,
              child: Text('Ollama'),
            ),
            DropdownMenuItem(
              value: AiProviderKind.openaiCompatible,
              child: Text('OpenAI-compatible'),
            ),
          ],
          onChanged: (value) => setState(() => _kind = value ?? _kind),
        ),
        const SizedBox(height: 10),
        TextFormField(
          controller: _name,
          decoration: const InputDecoration(labelText: '显示名称'),
          validator: _required,
        ),
        const SizedBox(height: 10),
        TextFormField(
          controller: _baseUrl,
          decoration: const InputDecoration(labelText: 'API 地址'),
          validator: _required,
        ),
        const SizedBox(height: 10),
        TextFormField(
          controller: _model,
          decoration: const InputDecoration(labelText: '模型'),
          validator: _required,
        ),
        if (_kind == AiProviderKind.openaiCompatible) ...[
          const SizedBox(height: 10),
          TextFormField(
            controller: _apiKey,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'API key（留空保持原密钥）'),
          ),
        ],
      ],
    ),
  );

  Widget _buildImport() => TextField(
    controller: _importController,
    minLines: 6,
    maxLines: 10,
    decoration: const InputDecoration(
      labelText: 'Provider JSON',
      hintText:
          '{"kind":"ollama","name":"本地","base_url":"http://localhost:11434","model":"qwen"}',
    ),
  );

  String? _required(String? value) =>
      value?.trim().isEmpty == false ? null : '不能为空';

  void _submit() {
    try {
      if (_importMode) {
        final decoded = jsonDecode(_importController.text);
        if (decoded is! Map) throw const FormatException('JSON 根节点必须是对象');
        final imported = AiProviderImport.fromJson(
          Map<String, dynamic>.from(decoded),
        );
        Navigator.pop(context, imported);
        return;
      }
      if (!(_formKey.currentState?.validate() ?? false)) return;
      final baseUrl = Uri.tryParse(_baseUrl.text.trim());
      if (baseUrl == null ||
          !baseUrl.hasAuthority ||
          !{'http', 'https'}.contains(baseUrl.scheme)) {
        throw const FormatException('请输入有效的 HTTP(S) 地址');
      }
      final current = widget.current;
      Navigator.pop(
        context,
        AiProviderImport(
          config: AiProviderConfig(
            id: current?.id ?? 'ai_${DateTime.now().microsecondsSinceEpoch}',
            name: _name.text.trim(),
            kind: _kind,
            baseUrl: _baseUrl.text.trim(),
            model: _model.text.trim(),
            enabled: current?.enabled ?? true,
            requestParameters: current?.requestParameters ?? const {},
            keyConfigured: current?.keyConfigured ?? false,
          ),
          apiKey: _apiKey.text.trim().isEmpty ? null : _apiKey.text.trim(),
        ),
      );
    } catch (error) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('配置无效：$error')));
    }
  }
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
