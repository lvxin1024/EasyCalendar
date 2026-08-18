import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../application/item_controller.dart';
import '../../config/app_config.dart';
import '../../data/service_probe_client.dart';
import '../../domain/item.dart';

enum _SetupMode { local, sync }

class FirstRunPage extends StatefulWidget {
  const FirstRunPage({
    super.key,
    required this.config,
    required this.controller,
  });

  final AppConfig config;
  final ItemController controller;

  @override
  State<FirstRunPage> createState() => _FirstRunPageState();
}

class _FirstRunPageState extends State<FirstRunPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _urlController;
  final _tokenController = TextEditingController();
  _SetupMode _mode = _SetupMode.local;
  bool _obscureToken = true;
  bool _testing = false;
  bool _saving = false;
  bool _connectionVerified = false;
  bool _diagnosisFailed = false;
  String? _diagnosis;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(
      text: widget.controller.preferences.apiUrl,
    );
  }

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.calendar_month,
                        size: 34,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          widget.config.appName,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),
                  Text('选择使用方式', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  SegmentedButton<_SetupMode>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: _SetupMode.local,
                        icon: Icon(Icons.computer_outlined),
                        label: Text('仅本地使用'),
                      ),
                      ButtonSegment(
                        value: _SetupMode.sync,
                        icon: Icon(Icons.cloud_sync_outlined),
                        label: Text('连接已有服务'),
                      ),
                    ],
                    selected: {_mode},
                    onSelectionChanged: _saving
                        ? null
                        : (values) => setState(() => _mode = values.first),
                  ),
                  const SizedBox(height: 24),
                  if (_mode == _SetupMode.local) ...[
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.storage_outlined),
                      title: const Text('数据保存在此设备'),
                      subtitle: const Text('之后可随时在设置中启用同步或配置 AI Provider。'),
                    ),
                    const SizedBox(height: 18),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.icon(
                        onPressed: _saving ? null : _finishLocal,
                        icon: const Icon(Icons.arrow_forward),
                        label: const Text('开始使用'),
                      ),
                    ),
                  ] else ...[
                    TextFormField(
                      controller: _urlController,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: '同步服务地址',
                        prefixIcon: Icon(Icons.link),
                      ),
                      validator: _validateUrl,
                      onChanged: (_) => _clearVerification(),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _tokenController,
                      obscureText: _obscureToken,
                      decoration: InputDecoration(
                        labelText: '同步服务令牌',
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
                      validator: _validateToken,
                      onChanged: (_) => _clearVerification(),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        OutlinedButton.icon(
                          onPressed: _testing || _saving ? null : _test,
                          icon: _testing
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.network_check),
                          label: const Text('测试连接'),
                        ),
                        if (_diagnosis != null) ...[
                          const SizedBox(width: 8),
                          IconButton(
                            tooltip: '复制诊断结果',
                            onPressed: _copyDiagnosis,
                            icon: const Icon(Icons.copy_outlined),
                          ),
                        ],
                      ],
                    ),
                    if (_diagnosis != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          _diagnosis!,
                          style: TextStyle(
                            color: _diagnosisFailed
                                ? Theme.of(context).colorScheme.error
                                : Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                    const SizedBox(height: 24),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        TextButton(
                          onPressed: _saving ? null : _finishLocal,
                          child: const Text('暂不连接'),
                        ),
                        FilledButton.icon(
                          onPressed:
                              _connectionVerified && !_testing && !_saving
                              ? _finishSync
                              : null,
                          icon: const Icon(Icons.cloud_done_outlined),
                          label: const Text('保存并启用同步'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  String? _validateUrl(String? raw) {
    final uri = Uri.tryParse(raw?.trim() ?? '');
    return uri != null &&
            uri.hasAuthority &&
            (uri.scheme == 'http' || uri.scheme == 'https')
        ? null
        : '请输入有效的 HTTP(S) 地址';
  }

  String? _validateToken(String? raw) =>
      (raw?.trim().length ?? 0) >= 32 ? null : '令牌至少需要 32 个字符';

  void _clearVerification() {
    if (!_connectionVerified && _diagnosis == null) return;
    setState(() {
      _connectionVerified = false;
      _diagnosis = null;
      _diagnosisFailed = false;
    });
  }

  Future<void> _test() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _testing = true;
      _diagnosis = null;
    });
    try {
      final result = await widget.controller.testServiceConnection(
        kind: ServiceKind.sync,
        serverUrl: _urlController.text,
        pendingToken: _tokenController.text,
      );
      if (!mounted) return;
      setState(() {
        _connectionVerified = true;
        _diagnosisFailed = false;
        _diagnosis = '同步服务连接成功 · v${result.serviceVersion} · 鉴权通过';
      });
    } on ServiceProbeException catch (error) {
      if (!mounted) return;
      setState(() {
        _connectionVerified = false;
        _diagnosisFailed = true;
        _diagnosis = error.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _connectionVerified = false;
        _diagnosisFailed = true;
        _diagnosis = '连接检测失败，请检查地址、网络和服务状态。';
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _finishLocal() => _save(
    widget.controller.preferences.copyWith(
      syncEnabled: false,
      onboardingCompleted: true,
    ),
  );

  Future<void> _finishSync() async {
    if (!_connectionVerified || !(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.controller.saveSyncToken(_tokenController.text);
      await widget.controller.savePreferences(
        widget.controller.preferences.copyWith(
          apiUrl: _urlController.text.trim(),
          syncEnabled: true,
          onboardingCompleted: true,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _diagnosisFailed = true;
        _diagnosis = '保存失败：$error';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _save(ClientPreferences preferences) async {
    setState(() => _saving = true);
    try {
      await widget.controller.savePreferences(preferences);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _diagnosisFailed = true;
        _diagnosis = '保存失败：$error';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _copyDiagnosis() async {
    final diagnosis = _diagnosis;
    if (diagnosis == null) return;
    await Clipboard.setData(ClipboardData(text: diagnosis));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('诊断结果已复制')));
  }
}
