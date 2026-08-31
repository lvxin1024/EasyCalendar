part of 'settings_page.dart';

class _ProviderDialog extends StatefulWidget {
  const _ProviderDialog({required this.controller, this.current});

  final ItemController controller;
  final AiProviderConfig? current;

  @override
  State<_ProviderDialog> createState() => _ProviderDialogState();
}

enum _ProviderPreset { ollama, openAI, deepSeek, custom }

class _ProviderDialogState extends State<_ProviderDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _model;
  late final TextEditingController _apiKey;
  late final TextEditingController _timeoutSeconds;
  late final TextEditingController _retryCount;
  late final TextEditingController _temperature;
  late final TextEditingController _maxTokens;
  late final TextEditingController _proxyUrl;
  late AiProviderKind _kind;
  late _ProviderPreset _preset;
  bool _importMode = false;
  bool _testing = false;
  bool _discovering = false;
  bool _testFailed = false;
  bool _clearApiKey = false;
  String? _testStatus;
  List<String> _discoveredModels = const [];
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
    _timeoutSeconds = TextEditingController(
      text:
          (current?.requestTimeoutSeconds ??
                  AiProviderConfig.defaultRequestTimeoutSeconds)
              .toString(),
    );
    _retryCount = TextEditingController(
      text: (current?.retryCount ?? AiProviderConfig.defaultRetryCount)
          .toString(),
    );
    _temperature = TextEditingController(
      text: (current?.temperature ?? 0).toString(),
    );
    _maxTokens = TextEditingController(
      text: current?.maxTokens?.toString() ?? '',
    );
    _proxyUrl = TextEditingController(text: current?.proxyUrl ?? '');
    _kind = current?.kind ?? AiProviderKind.ollama;
    _preset = switch (current?.baseUrl) {
      null || 'http://localhost:11434' => _ProviderPreset.ollama,
      'https://api.openai.com/v1' => _ProviderPreset.openAI,
      'https://api.deepseek.com' => _ProviderPreset.deepSeek,
      _ => _ProviderPreset.custom,
    };
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _model.dispose();
    _apiKey.dispose();
    _timeoutSeconds.dispose();
    _retryCount.dispose();
    _temperature.dispose();
    _maxTokens.dispose();
    _proxyUrl.dispose();
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
        DropdownButtonFormField<_ProviderPreset>(
          key: ValueKey(_preset),
          initialValue: _preset,
          decoration: const InputDecoration(labelText: '预设'),
          items: const [
            DropdownMenuItem(
              value: _ProviderPreset.ollama,
              child: Text('Ollama（本机）'),
            ),
            DropdownMenuItem(
              value: _ProviderPreset.openAI,
              child: Text('OpenAI-compatible'),
            ),
            DropdownMenuItem(
              value: _ProviderPreset.deepSeek,
              child: Text('DeepSeek'),
            ),
            DropdownMenuItem(value: _ProviderPreset.custom, child: Text('自定义')),
          ],
          onChanged: (value) {
            if (value != null) _applyPreset(value);
          },
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<AiProviderKind>(
          key: ValueKey(_kind),
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
          onChanged: (value) => setState(() {
            _kind = value ?? _kind;
            _preset = _ProviderPreset.custom;
            _discoveredModels = const [];
          }),
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
          onChanged: (_) => setState(() {
            _preset = _ProviderPreset.custom;
            _discoveredModels = const [];
          }),
        ),
        const SizedBox(height: 10),
        TextFormField(
          controller: _model,
          decoration: const InputDecoration(labelText: '模型'),
          validator: _required,
        ),
        if (_kind == AiProviderKind.openaiCompatible) ...[
          const SizedBox(height: 10),
          Text(
            widget.current?.keyConfigured == true && !_clearApiKey
                ? 'API Key：已配置（不会回显）'
                : _clearApiKey
                ? 'API Key：保存后清除'
                : 'API Key：未配置',
          ),
          if (widget.current?.keyConfigured == true)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() {
                  _clearApiKey = !_clearApiKey;
                  if (_clearApiKey) _apiKey.clear();
                }),
                icon: Icon(_clearApiKey ? Icons.undo : Icons.key_off_outlined),
                label: Text(_clearApiKey ? '撤销清除' : '清除密钥'),
              ),
            ),
          TextFormField(
            controller: _apiKey,
            obscureText: true,
            enabled: !_clearApiKey,
            decoration: InputDecoration(
              labelText: widget.current?.keyConfigured == true
                  ? '替换 API Key（留空则保留）'
                  : 'API Key',
            ),
            onChanged: (_) => setState(() {
              _clearApiKey = false;
              _discoveredModels = const [];
            }),
          ),
        ],
        const SizedBox(height: 10),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('请求参数'),
          children: [
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _timeoutSeconds,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '超时（秒）'),
                    validator: (value) => _integerRange(
                      value,
                      minimum: 5,
                      maximum: 300,
                      required: true,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextFormField(
                    controller: _retryCount,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '失败重试次数'),
                    validator: (value) => _integerRange(
                      value,
                      minimum: 0,
                      maximum: 5,
                      required: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _temperature,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(labelText: 'Temperature'),
                    validator: _temperatureRange,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextFormField(
                    controller: _maxTokens,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '最大输出 Token（可选）',
                    ),
                    validator: (value) => _integerRange(
                      value,
                      minimum: 1,
                      maximum: 1000000,
                      required: false,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _proxyUrl,
              decoration: const InputDecoration(
                labelText: 'HTTP 代理（可选）',
                hintText: 'http://127.0.0.1:7890',
              ),
              validator: _proxyValidator,
            ),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            onPressed: _discovering || _testing ? null : _discoverModels,
            icon: _discovering
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.manage_search),
            label: const Text('获取模型列表'),
          ),
        ),
        if (_discoveredModels.isNotEmpty) ...[
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            key: ValueKey(_discoveredModels.join('\u0000')),
            initialValue: _discoveredModels.contains(_model.text)
                ? _model.text
                : null,
            decoration: const InputDecoration(labelText: '发现的模型'),
            items: [
              for (final model in _discoveredModels)
                DropdownMenuItem(value: model, child: Text(model)),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _model.text = value);
            },
          ),
        ],
        _testControls(),
      ],
    ),
  );

  Widget _buildImport() => ListView(
    shrinkWrap: true,
    children: [
      TextField(
        controller: _importController,
        minLines: 6,
        maxLines: 10,
        decoration: const InputDecoration(
          labelText: 'Provider JSON',
          hintText:
              '{"kind":"ollama","name":"本地","base_url":"http://localhost:11434","model":"qwen"}',
        ),
      ),
      _testControls(),
    ],
  );

  Widget _testControls() => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: _testing ? null : _testConnection,
              icon: _testing
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.network_check),
              label: const Text('测试连接'),
            ),
            if (_testStatus != null)
              IconButton(
                tooltip: '复制诊断结果',
                onPressed: _copyTestStatus,
                icon: const Icon(Icons.copy_outlined),
              ),
          ],
        ),
        if (_testStatus != null)
          Text(
            _testStatus!,
            style: TextStyle(
              color: _testFailed
                  ? Theme.of(context).colorScheme.error
                  : Theme.of(context).colorScheme.primary,
            ),
          ),
      ],
    ),
  );

  String? _required(String? value) =>
      value?.trim().isEmpty == false ? null : '不能为空';

  String? _integerRange(
    String? value, {
    required int minimum,
    required int maximum,
    required bool required,
  }) {
    final text = value?.trim() ?? '';
    if (text.isEmpty && !required) return null;
    final parsed = int.tryParse(text);
    if (parsed == null || parsed < minimum || parsed > maximum) {
      return '请输入 $minimum-$maximum 的整数';
    }
    return null;
  }

  String? _temperatureRange(String? value) {
    final parsed = double.tryParse(value?.trim() ?? '');
    if (parsed == null || parsed < 0 || parsed > 2) return '请输入 0-2 的数字';
    return null;
  }

  String? _proxyValidator(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return null;
    final proxy = Uri.tryParse(text);
    if (proxy == null ||
        proxy.scheme != 'http' ||
        !proxy.hasAuthority ||
        proxy.host.isEmpty ||
        proxy.userInfo.isNotEmpty) {
      return '请输入无用户名密码的 HTTP 代理地址';
    }
    return null;
  }

  void _applyPreset(_ProviderPreset preset) {
    setState(() {
      _preset = preset;
      _discoveredModels = const [];
      switch (preset) {
        case _ProviderPreset.ollama:
          _kind = AiProviderKind.ollama;
          _name.text = 'Ollama';
          _baseUrl.text = 'http://localhost:11434';
          break;
        case _ProviderPreset.openAI:
          _kind = AiProviderKind.openaiCompatible;
          _name.text = 'OpenAI';
          _baseUrl.text = 'https://api.openai.com/v1';
          break;
        case _ProviderPreset.deepSeek:
          _kind = AiProviderKind.openaiCompatible;
          _name.text = 'DeepSeek';
          _baseUrl.text = 'https://api.deepseek.com';
          break;
        case _ProviderPreset.custom:
          break;
      }
    });
  }

  Future<void> _discoverModels() async {
    AiProviderImport imported;
    try {
      if (_importMode) {
        final value = _readConfiguration();
        if (value == null) return;
        imported = value;
      } else {
        final baseUrl = Uri.tryParse(_baseUrl.text.trim());
        if (baseUrl == null ||
            !baseUrl.hasAuthority ||
            baseUrl.userInfo.isNotEmpty ||
            !{'http', 'https'}.contains(baseUrl.scheme)) {
          throw const FormatException('请输入有效的 HTTP(S) 地址');
        }
        imported = AiProviderImport(
          config: AiProviderConfig(
            id:
                widget.current?.id ??
                'ai_${DateTime.now().microsecondsSinceEpoch}',
            name: _name.text.trim().isEmpty ? 'Provider' : _name.text.trim(),
            kind: _kind,
            baseUrl: _baseUrl.text.trim(),
            model: _model.text.trim().isEmpty
                ? 'discovery'
                : _model.text.trim(),
            requestParameters: _readRequestParameters(),
            keyConfigured: widget.current?.keyConfigured ?? false,
          ),
          apiKey: _apiKey.text.trim().isEmpty ? null : _apiKey.text.trim(),
        );
      }
    } catch (error) {
      setState(() {
        _testFailed = true;
        _testStatus = '配置无效：$error';
      });
      return;
    }
    setState(() {
      _discovering = true;
      _testStatus = null;
    });
    try {
      final models = await widget.controller.discoverAiModels(
        imported.config,
        pendingApiKey: imported.apiKey ?? '',
      );
      if (!mounted) return;
      setState(() {
        _discoveredModels = models;
        _testFailed = false;
        _testStatus = '已发现 ${models.length} 个模型';
      });
    } on AiProviderProbeException catch (error) {
      if (!mounted) return;
      setState(() {
        _testFailed = true;
        _testStatus = '${error.message} 仍可手动填写模型名称。';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _testFailed = true;
        _testStatus = '模型发现失败，仍可手动填写模型名称。';
      });
    } finally {
      if (mounted) setState(() => _discovering = false);
    }
  }

  void _submit() {
    try {
      final imported = _readConfiguration();
      if (imported != null) Navigator.pop(context, imported);
    } catch (error) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('配置无效：$error')));
    }
  }

  AiProviderImport? _readConfiguration() {
    if (_importMode) {
      final decoded = jsonDecode(_importController.text);
      if (decoded is! Map) throw const FormatException('JSON 根节点必须是对象');
      return AiProviderImport.fromJson(Map<String, dynamic>.from(decoded));
    }
    if (!(_formKey.currentState?.validate() ?? false)) return null;
    final baseUrl = Uri.tryParse(_baseUrl.text.trim());
    if (baseUrl == null ||
        !baseUrl.hasAuthority ||
        baseUrl.userInfo.isNotEmpty ||
        !{'http', 'https'}.contains(baseUrl.scheme)) {
      throw const FormatException('请输入有效的 HTTP(S) 地址');
    }
    final current = widget.current;
    return AiProviderImport(
      config: AiProviderConfig(
        id: current?.id ?? 'ai_${DateTime.now().microsecondsSinceEpoch}',
        name: _name.text.trim(),
        kind: _kind,
        baseUrl: _baseUrl.text.trim(),
        model: _model.text.trim(),
        enabled: current?.enabled ?? true,
        requestParameters: _readRequestParameters(),
        keyConfigured: current?.keyConfigured ?? false,
      ),
      apiKey: _apiKey.text.trim().isEmpty ? null : _apiKey.text.trim(),
      clearApiKey: _clearApiKey,
    );
  }

  Map<String, dynamic> _readRequestParameters() {
    final parameters = <String, dynamic>{...?widget.current?.requestParameters}
      ..removeWhere(
        (key, _) => const {
          'request_timeout_seconds',
          'retry_count',
          'temperature',
          'max_tokens',
          'proxy_url',
        }.contains(key),
      );
    parameters['request_timeout_seconds'] = int.parse(
      _timeoutSeconds.text.trim(),
    );
    parameters['retry_count'] = int.parse(_retryCount.text.trim());
    parameters['temperature'] = double.parse(_temperature.text.trim());
    final maxTokens = int.tryParse(_maxTokens.text.trim());
    if (maxTokens != null) parameters['max_tokens'] = maxTokens;
    final proxyUrl = _proxyUrl.text.trim();
    if (proxyUrl.isNotEmpty) parameters['proxy_url'] = proxyUrl;
    return parameters;
  }

  Future<void> _testConnection() async {
    AiProviderImport? imported;
    try {
      imported = _readConfiguration();
    } catch (error) {
      setState(() {
        _testFailed = true;
        _testStatus = '配置无效：$error';
      });
      return;
    }
    if (imported == null) return;
    setState(() {
      _testing = true;
      _testStatus = null;
    });
    try {
      await widget.controller.testAiProvider(
        imported.config,
        pendingApiKey: imported.apiKey ?? '',
      );
      if (!mounted) return;
      setState(() {
        _testFailed = false;
        _testStatus = 'Provider 连接成功';
      });
    } on AiProviderProbeException catch (error) {
      if (!mounted) return;
      setState(() {
        _testFailed = true;
        _testStatus = error.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _testFailed = true;
        _testStatus = 'Provider 连接失败，请检查地址和网络。';
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _copyTestStatus() async {
    final status = _testStatus;
    if (status == null) return;
    await Clipboard.setData(ClipboardData(text: status));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('诊断结果已复制')));
  }
}
