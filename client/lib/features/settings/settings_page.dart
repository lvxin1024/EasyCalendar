import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../ai/ai_provider.dart';
import '../../ai/ai_provider_connection_tester.dart';
import '../../application/item_controller.dart';
import '../../config/app_config.dart';
import '../../data/calendar_connection_code.dart';
import '../../data/service_probe_client.dart';
import '../../device/device_identity.dart';
import '../../domain/item.dart';
import '../../notification/notification_adapter.dart';
import '../../sync/sync_models.dart';
import '../../utils/tag_colors.dart';
import '../../widgets/tag_filter_bar.dart';
import '../recycle_bin/recycle_bin_page.dart';
import '../transfer/transfer_page.dart';
import 'about_page.dart';

part 'settings_provider_dialog.dart';
part 'settings_sections.dart';

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
  late List<String> _widgetQuotes;
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
    _widgetQuotes = [...preferences.widgetQuotes];
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
              DropdownButtonFormField<String>(
                key: ValueKey(_collectionIdController.text),
                initialValue:
                    widget.controller.collections.any(
                      (collection) =>
                          !collection.readonly &&
                          collection.id == _collectionIdController.text,
                    )
                    ? _collectionIdController.text
                    : null,
                decoration: const InputDecoration(
                  labelText: '默认日历',
                  helperText: '新建事项默认保存到这里',
                  prefixIcon: Icon(Icons.calendar_today_outlined),
                ),
                items: [
                  for (final collection in widget.controller.collections)
                    if (!collection.readonly)
                      DropdownMenuItem(
                        value: collection.id,
                        child: Text(collection.name),
                      ),
                ],
                onChanged: _selectDefaultCollection,
                validator: (value) => value == null ? '请选择默认日历' : null,
              ),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _importCalendarConnectionCode,
                    icon: const Icon(Icons.link_outlined),
                    label: const Text('连接已有日历'),
                  ),
                  TextButton.icon(
                    onPressed: _copyCalendarConnectionCode,
                    icon: const Icon(Icons.ios_share_outlined),
                    label: const Text('复制日历配置码'),
                  ),
                ],
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
                    readOnly: true,
                    decoration: InputDecoration(
                      labelText: '默认 Collection ID',
                      helperText: '由 App 自动维护；切换默认日历不会迁移旧事项',
                      prefixIcon: const Icon(Icons.folder_outlined),
                      suffixIcon: IconButton(
                        tooltip: '复制 Collection ID',
                        onPressed: _copyCollectionId,
                        icon: const Icon(Icons.copy_outlined),
                      ),
                    ),
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
                  } else {
                    await widget.controller.notificationService?.cancelAll();
                  }
                  if (mounted) setState(() {});
                },
              ),
              if (widget.controller.notificationService != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.shield_outlined, size: 20),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              '系统权限：${widget.controller.notificationService!.statusText}',
                            ),
                          ),
                          IconButton(
                            tooltip: '刷新权限状态',
                            onPressed: _refreshNotificationPermission,
                            icon: const Icon(Icons.refresh),
                          ),
                        ],
                      ),
                      Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _requestNotificationPermission,
                            icon: const Icon(
                              Icons.notifications_active_outlined,
                            ),
                            label: const Text('申请权限'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _openNotificationSettings,
                            icon: const Icon(Icons.settings_outlined),
                            label: const Text('系统设置'),
                          ),
                          FilledButton.tonalIcon(
                            onPressed:
                                widget.controller.notificationService!.available
                                ? _showTestNotification
                                : null,
                            icon: const Icon(Icons.send_outlined),
                            label: const Text('测试通知'),
                          ),
                        ],
                      ),
                    ],
                  ),
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
              _WidgetQuoteSection(
                quotes: _widgetQuotes,
                onAdd: _widgetQuotes.length >= 10
                    ? null
                    : () => _editWidgetQuote(),
                onEdit: (index) => _editWidgetQuote(index),
                onDelete: (index) => setState(
                  () => _widgetQuotes = [..._widgetQuotes]..removeAt(index),
                ),
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
                key: ValueKey(_localeName),
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
                key: ValueKey(_timezone),
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
                key: ValueKey(_firstDayOfWeek),
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
                key: ValueKey(_clockFormat),
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
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => Scaffold(
                        appBar: AppBar(title: const Text('导入导出')),
                        body: TransferPage(controller: widget.controller),
                      ),
                    ),
                  );
                  if (mounted) _reloadPreferencesIntoForm();
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
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('关于与更新'),
                subtitle: const Text('查看版本并检查 GitHub Release'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.of(
                    context,
                  ).push(MaterialPageRoute(builder: (_) => const AboutPage()));
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
          onboardingCompleted:
              widget.controller.preferences.onboardingCompleted,
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
          widgetQuotes: _widgetQuotes,
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

  void _reloadPreferencesIntoForm() {
    final preferences = widget.controller.preferences;
    setState(() {
      _apiUrlController.text = preferences.apiUrl;
      _featureApiUrlController.text = preferences.featureApiUrl;
      _deviceNameController.text = preferences.deviceName;
      _deviceIdController.text = preferences.deviceId;
      _collectionIdController.text = preferences.defaultCollectionId;
      _collectionNameController.text = preferences.defaultCollectionName;
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
      _widgetQuotes = [...preferences.widgetQuotes];
    });
  }

  Future<void> _editWidgetQuote([int? index]) async {
    final controller = TextEditingController(
      text: index == null ? '' : _widgetQuotes[index],
    );
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(index == null ? '添加小组件文案' : '编辑小组件文案'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 160,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: '文案',
            hintText: 'every day u fight like ur running out of time',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || value == null || value.isEmpty) return;
    setState(() {
      if (index == null) {
        _widgetQuotes = [..._widgetQuotes, value];
      } else {
        _widgetQuotes = [..._widgetQuotes]..[index] = value;
      }
    });
  }

  Future<void> _copyDeviceId() async {
    await Clipboard.setData(ClipboardData(text: _deviceIdController.text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('设备 ID 已复制')));
  }

  Future<void> _copyCollectionId() async {
    await Clipboard.setData(ClipboardData(text: _collectionIdController.text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Collection ID 已复制')));
  }

  Future<void> _copyCalendarConnectionCode() async {
    CalendarCollection? collection;
    for (final candidate in widget.controller.collections) {
      if (!candidate.readonly && candidate.id == _collectionIdController.text) {
        collection = candidate;
        break;
      }
    }
    if (collection == null) return;
    final code = CalendarConnectionCode(
      collectionId: collection.id,
      name: collection.name,
      color: collection.color,
    ).encode();
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('日历配置码已复制')));
  }

  Future<void> _importCalendarConnectionCode() async {
    final input = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('连接已有日历'),
        content: SizedBox(
          width: 460,
          child: TextField(
            controller: input,
            minLines: 3,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: '日历配置码',
              hintText: 'ECAL1-...',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, input.text.trim()),
            icon: const Icon(Icons.link),
            label: const Text('连接'),
          ),
        ],
      ),
    );
    input.dispose();
    if (code == null || code.isEmpty) return;
    try {
      final collection = await widget.controller.connectCollection(code);
      if (!mounted) return;
      setState(() {
        _collectionIdController.text = collection.id;
        _collectionNameController.text = collection.name;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已连接“${collection.name}”，同步后将获取已有内容')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('连接日历失败：$error')));
    }
  }

  void _selectDefaultCollection(String? collectionId) {
    if (collectionId == null) return;
    for (final collection in widget.controller.collections) {
      if (collection.id != collectionId || collection.readonly) continue;
      setState(() {
        _collectionIdController.text = collection.id;
        _collectionNameController.text = collection.name;
      });
      return;
    }
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
        final updated = await widget.controller.updateCollection(
          current,
          name: result.name,
          color: result.color.toARGB32(),
        );
        if (_collectionIdController.text == updated.id) {
          _collectionNameController.text = updated.name;
        }
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
      if (_collectionIdController.text == collection.id && mounted) {
        setState(() {
          _collectionIdController.text =
              widget.controller.preferences.defaultCollectionId;
          _collectionNameController.text =
              widget.controller.preferences.defaultCollectionName;
        });
      }
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
      builder: (_) =>
          _ProviderDialog(controller: widget.controller, current: current),
    );
    if (imported == null) return;
    try {
      await widget.controller.saveAiProvider(
        imported.config,
        apiKey: imported.apiKey,
        clearApiKey: imported.clearApiKey,
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

  Future<void> _requestNotificationPermission() async {
    final service = widget.controller.notificationService;
    if (service == null) return;
    final status = await service.requestPermission();
    if (status == NotificationPermissionStatus.granted &&
        _notificationsEnabled) {
      await service.reconcileAll(widget.controller.items);
    }
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          status == NotificationPermissionStatus.granted
              ? '通知权限已授予'
              : '通知权限未授予，本地事项仍会正常保存',
        ),
      ),
    );
  }

  Future<void> _refreshNotificationPermission() async {
    await widget.controller.notificationService?.refreshPermission();
    if (mounted) setState(() {});
  }

  Future<void> _openNotificationSettings() async {
    final opened =
        await widget.controller.notificationService?.openSystemSettings() ??
        false;
    if (!mounted || opened) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('无法打开系统通知设置')));
  }

  Future<void> _showTestNotification() async {
    try {
      await widget.controller.notificationService?.showTestNotification();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('测试通知已发送')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('测试通知失败：$error')));
    }
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
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      border: Border(
        bottom: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
    ),
    child: ListTile(
      leading: Icon(icon),
      title: Text(label),
      subtitle: Text(value, maxLines: 2, overflow: TextOverflow.ellipsis),
    ),
  );
}
