import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../application/item_controller.dart';
import '../../sync/p2p_bridge.dart';
import '../../sync/sync_group.dart';

class SyncGroupSetupPanel extends StatefulWidget {
  const SyncGroupSetupPanel({
    super.key,
    required this.controller,
    this.onProfileChanged,
  });

  final ItemController controller;
  final ValueChanged<SyncGroupProfile?>? onProfileChanged;

  @override
  State<SyncGroupSetupPanel> createState() => _SyncGroupSetupPanelState();
}

class _SyncGroupSetupPanelState extends State<SyncGroupSetupPanel> {
  final _codeController = TextEditingController();
  SyncGroupProfile? _profile;
  bool _loading = true;
  bool _working = false;
  bool _showJoinForm = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.hub_outlined,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '群组同步',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (_loading)
                const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '设备之间直接同步。创建群组的设备作为主节点，其他设备使用同步码加入。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (_profile != null) ...[
            const SizedBox(height: 16),
            _ProfileSummary(profile: _profile!),
            const SizedBox(height: 10),
            FutureBuilder<String?>(
              future: widget.controller.exportSyncGroupCode(),
              builder: (context, snapshot) {
                final code = snapshot.data;
                if (code == null || code.isEmpty) {
                  return const SizedBox.shrink();
                }
                return InputDecorator(
                  decoration: InputDecoration(
                    labelText: '同步码',
                    suffixIcon: IconButton(
                      tooltip: '复制同步码',
                      onPressed: () => _copy(code),
                      icon: const Icon(Icons.copy_outlined),
                    ),
                  ),
                  child: SelectableText(code),
                );
              },
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _working ? null : _clear,
                icon: const Icon(Icons.link_off_outlined),
                label: const Text('清除群组配置'),
              ),
            ),
          ] else ...[
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (_showJoinForm) ...[
                  OutlinedButton.icon(
                    onPressed: _working || _loading ? null : _cancelJoin,
                    icon: const Icon(Icons.close),
                    label: const Text('取消加入'),
                  ),
                  FilledButton.icon(
                    onPressed: _working || _loading ? null : _join,
                    icon: const Icon(Icons.login_outlined),
                    label: const Text('加入同步组'),
                  ),
                ] else ...[
                  FilledButton.icon(
                    onPressed: _working || _loading ? null : _create,
                    icon: const Icon(Icons.add_link),
                    label: const Text('创建同步组'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _working || _loading ? null : _showJoin,
                    icon: const Icon(Icons.login_outlined),
                    label: const Text('加入同步组'),
                  ),
                ],
              ],
            ),
            if (_showJoinForm) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _codeController,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: '粘贴 ECG1 同步码',
                  hintText: 'ECG1-...',
                  prefixIcon: Icon(Icons.qr_code_2_outlined),
                ),
              ),
            ],
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    ),
  );

  Future<void> _loadProfile() async {
    try {
      final profile = await widget.controller.loadSyncGroupProfile();
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _loading = false;
      });
      widget.onProfileChanged?.call(profile);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '读取群组配置失败：$error';
      });
    }
  }

  Future<void> _create() async {
    final bridge = _loadBridge();
    if (bridge == null) return;
    await _run(() => widget.controller.createSyncGroupAutomatically(bridge));
  }

  Future<void> _join() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      setState(() => _error = '请先粘贴 ECG1 同步码。');
      return;
    }
    final bridge = _loadBridge();
    if (bridge == null) return;
    await _run(
      () => widget.controller.joinSyncGroupAutomatically(code, bridge),
    );
  }

  void _showJoin() {
    setState(() {
      _showJoinForm = true;
      _error = null;
    });
  }

  void _cancelJoin() {
    setState(() {
      _showJoinForm = false;
      _codeController.clear();
      _error = null;
    });
  }

  P2pBridge? _loadBridge() {
    return IsolateP2pBridge();
  }

  Future<void> _run(Future<SyncGroupProfile> Function() operation) async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final profile = await operation();
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _working = false;
      });
      widget.onProfileChanged?.call(profile);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _error = '群组配置失败：$error';
      });
    }
  }

  Future<void> _clear() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.controller.clearSyncGroup();
      if (!mounted) return;
      setState(() {
        _profile = null;
        _working = false;
      });
      widget.onProfileChanged?.call(null);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _error = '清除群组配置失败：$error';
      });
    }
  }

  Future<void> _copy(String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('同步码已复制')));
  }
}

class _ProfileSummary extends StatelessWidget {
  const _ProfileSummary({required this.profile});

  final SyncGroupProfile profile;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(
        profile.role == SyncGroupRole.primary
            ? Icons.star_outline
            : Icons.devices_other_outlined,
        color: Theme.of(context).colorScheme.primary,
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Text(
          profile.role == SyncGroupRole.primary
              ? '当前设备是主节点，其他设备可使用下方同步码加入。'
              : '当前设备已加入同步组，主节点在线时会自动同步。',
        ),
      ),
    ],
  );
}
