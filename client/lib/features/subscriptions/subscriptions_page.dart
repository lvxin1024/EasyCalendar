import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../application/item_controller.dart';
import '../../data/subscription_api_client.dart';
import '../../domain/subscription.dart';
import '../../sync/token_store.dart';

class SubscriptionsPage extends StatefulWidget {
  const SubscriptionsPage({super.key, required this.controller});

  final ItemController controller;

  @override
  State<SubscriptionsPage> createState() => _SubscriptionsPageState();
}

class _SubscriptionsPageState extends State<SubscriptionsPage> {
  late final SubscriptionApiClient _client;
  List<CalendarSubscription> _subscriptions = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _client = SubscriptionApiClient(
      tokenStore:
          widget.controller.syncCoordinator?.tokenStore ??
          SecureSyncTokenStore(),
    );
    unawaited(_reload());
  }

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
        padding: const EdgeInsets.fromLTRB(24, 24, 20, 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '网址订阅',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            IconButton(
              tooltip: '刷新订阅列表',
              onPressed: _loading ? null : _reload,
              icon: const Icon(Icons.refresh),
            ),
            FilledButton.tonalIcon(
              onPressed: _showCreateDialog,
              icon: const Icon(Icons.add_link),
              label: const Text('添加订阅'),
            ),
          ],
        ),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      Expanded(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _subscriptions.isEmpty
            ? const Center(child: Text('还没有网址订阅'))
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 96),
                itemCount: _subscriptions.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) => _SubscriptionTile(
                  subscription: _subscriptions[index],
                  onToggle: (enabled) =>
                      _toggle(_subscriptions[index], enabled),
                  onEdit: () => _showEditDialog(_subscriptions[index]),
                  onRefresh: () => _refresh(_subscriptions[index]),
                  onLogs: () => _showLogs(_subscriptions[index]),
                  onDelete: () => _delete(_subscriptions[index]),
                ),
              ),
      ),
    ],
  );

  Uri? get _baseUrl => Uri.tryParse(widget.controller.preferences.apiUrl);

  Future<void> _reload() async {
    final base = _baseUrl;
    if (base == null || !base.hasAuthority) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '同步服务地址无效。';
        });
      }
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final values = await _client.list(base);
      if (mounted) setState(() => _subscriptions = values);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _showCreateDialog() async {
    final draft = await showDialog<_SubscriptionDraft>(
      context: context,
      builder: (_) => const _SubscriptionDialog(),
    );
    final base = _baseUrl;
    if (draft == null || base == null) return;
    try {
      await _client.create(
        base,
        title: draft.title,
        url: draft.url,
        refreshIntervalMinutes: draft.refreshIntervalMinutes,
      );
      await _reload();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _showEditDialog(CalendarSubscription current) async {
    final draft = await showDialog<_SubscriptionDraft>(
      context: context,
      builder: (_) => _SubscriptionDialog(initial: current),
    );
    final base = _baseUrl;
    if (draft == null || base == null) return;
    try {
      await _client.update(
        base,
        current,
        patch: {
          'title': draft.title,
          'url': draft.url,
          'refresh_interval_minutes': draft.refreshIntervalMinutes,
        },
      );
      await _reload();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _toggle(CalendarSubscription current, bool enabled) async {
    final base = _baseUrl;
    if (base == null) return;
    try {
      await _client.update(base, current, patch: {'enabled': enabled});
      await _reload();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _refresh(CalendarSubscription current) async {
    final base = _baseUrl;
    if (base == null) return;
    try {
      await _client.refresh(base, current);
      await _reload();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _delete(CalendarSubscription current) async {
    final base = _baseUrl;
    if (base == null) return;
    try {
      await _client.delete(base, current);
      await _reload();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _showLogs(CalendarSubscription current) async {
    final base = _baseUrl;
    if (base == null) return;
    try {
      final logs = await _client.logs(base, current);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${current.title} · 抓取记录'),
          content: SizedBox(
            width: 520,
            child: logs.isEmpty
                ? const Text('暂无抓取记录')
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: logs.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final log = logs[index];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          log.status == 'success'
                              ? Icons.check_circle_outline
                              : Icons.error_outline,
                        ),
                        title: Text(log.status),
                        subtitle: Text(
                          '${_time(log.fetchedAt)}'
                          '${log.httpStatus == null ? '' : ' · HTTP ${log.httpStatus}'}'
                          '\n新增 ${log.createdCount} · 更新 ${log.updatedCount} · 删除 ${log.deletedCount} · 未变 ${log.unchangedCount}'
                          '${log.etag == null ? '' : '\nETag ${_short(log.etag!)}'}'
                          '${log.sourceHash == null ? '' : ' · 哈希 ${_short(log.sourceHash!)}'}'
                          '${log.error == null ? '' : '\n${log.error}'}',
                        ),
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
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  static String _time(DateTime? value) => value == null
      ? '未知时间'
      : DateFormat('yyyy-MM-dd HH:mm', 'zh_CN').format(value.toLocal());

  static String _short(String value) =>
      value.length <= 18 ? value : '${value.substring(0, 18)}…';
}

class _SubscriptionTile extends StatelessWidget {
  const _SubscriptionTile({
    required this.subscription,
    required this.onToggle,
    required this.onEdit,
    required this.onRefresh,
    required this.onLogs,
    required this.onDelete,
  });

  final CalendarSubscription subscription;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onRefresh;
  final VoidCallback onLogs;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final hasError = subscription.lastError?.isNotEmpty == true;
    final status = hasError
        ? '最近错误：${subscription.lastError}'
        : '最近成功：${_SubscriptionsPageState._time(subscription.lastSuccessAt)}';
    final etag = subscription.etag;
    final sourceHash = subscription.sourceHash;
    return Card(
      child: ListTile(
        leading: Icon(
          hasError ? Icons.sync_problem_outlined : Icons.link,
          color: hasError
              ? Theme.of(context).colorScheme.error
              : Theme.of(context).colorScheme.primary,
        ),
        title: Text(subscription.title),
        subtitle: Text(
          '${subscription.url}\n'
          '每 ${_interval(subscription.refreshIntervalMinutes)}刷新 · $status'
          '${etag == null ? '' : '\nETag ${_SubscriptionsPageState._short(etag)}'}'
          '${sourceHash == null ? '' : ' · 哈希 ${_SubscriptionsPageState._short(sourceHash)}'}',
          maxLines: 5,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '立即刷新',
              onPressed: onRefresh,
              icon: const Icon(Icons.sync),
            ),
            Switch(value: subscription.enabled, onChanged: onToggle),
            PopupMenuButton<_SubscriptionAction>(
              tooltip: '更多操作',
              onSelected: (value) {
                switch (value) {
                  case _SubscriptionAction.edit:
                    onEdit();
                  case _SubscriptionAction.logs:
                    onLogs();
                  case _SubscriptionAction.delete:
                    onDelete();
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: _SubscriptionAction.edit,
                  child: ListTile(
                    leading: Icon(Icons.edit_outlined),
                    title: Text('编辑'),
                  ),
                ),
                PopupMenuItem(
                  value: _SubscriptionAction.logs,
                  child: ListTile(
                    leading: Icon(Icons.history_outlined),
                    title: Text('抓取记录'),
                  ),
                ),
                PopupMenuItem(
                  value: _SubscriptionAction.delete,
                  child: ListTile(
                    leading: Icon(Icons.delete_outline),
                    title: Text('删除'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _interval(int minutes) {
    if (minutes % 1440 == 0) return '${minutes ~/ 1440} 天';
    if (minutes % 60 == 0) return '${minutes ~/ 60} 小时';
    return '$minutes 分钟';
  }
}

enum _SubscriptionAction { edit, logs, delete }

class _SubscriptionDraft {
  const _SubscriptionDraft({
    required this.title,
    required this.url,
    required this.refreshIntervalMinutes,
  });

  final String title;
  final String url;
  final int refreshIntervalMinutes;
}

class _SubscriptionDialog extends StatefulWidget {
  const _SubscriptionDialog({this.initial});

  final CalendarSubscription? initial;

  @override
  State<_SubscriptionDialog> createState() => _SubscriptionDialogState();
}

class _SubscriptionDialogState extends State<_SubscriptionDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _url;
  late int _refreshIntervalMinutes;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.initial?.title);
    _url = TextEditingController(text: widget.initial?.url);
    _refreshIntervalMinutes = widget.initial?.refreshIntervalMinutes ?? 60;
  }

  @override
  void dispose() {
    _title.dispose();
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.initial == null ? '添加网址订阅' : '编辑网址订阅'),
    content: SizedBox(
      width: 520,
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _title,
              autofocus: true,
              decoration: const InputDecoration(labelText: '显示名称'),
              validator: (value) =>
                  value == null || value.trim().isEmpty ? '请输入显示名称' : null,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: _refreshIntervalMinutes,
              decoration: const InputDecoration(labelText: '刷新间隔'),
              items: _intervalOptions
                  .map(
                    (minutes) => DropdownMenuItem(
                      value: minutes,
                      child: Text(_SubscriptionTile._interval(minutes)),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (value) {
                if (value != null) _refreshIntervalMinutes = value;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _url,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: 'ICS URL'),
              validator: (value) {
                final uri = Uri.tryParse(value?.trim() ?? '');
                return uri == null ||
                        !uri.hasAuthority ||
                        (uri.scheme != 'http' && uri.scheme != 'https')
                    ? '请输入有效的 HTTP(S) 地址'
                    : null;
              },
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (!(_formKey.currentState?.validate() ?? false)) return;
          Navigator.pop(
            context,
            _SubscriptionDraft(
              title: _title.text.trim(),
              url: _url.text.trim(),
              refreshIntervalMinutes: _refreshIntervalMinutes,
            ),
          );
        },
        child: Text(widget.initial == null ? '添加' : '保存'),
      ),
    ],
  );
}

const _intervalOptions = [15, 30, 60, 180, 360, 720, 1440];
