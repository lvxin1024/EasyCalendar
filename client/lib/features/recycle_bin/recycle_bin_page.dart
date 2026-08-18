import 'package:flutter/material.dart';

import '../../application/item_controller.dart';
import '../../domain/item.dart';
import '../../utils/configured_time.dart';
import '../../utils/date_formatters.dart';
import '../../widgets/empty_state.dart';

class RecycleBinPage extends StatefulWidget {
  const RecycleBinPage({super.key, required this.controller});

  final ItemController controller;

  @override
  State<RecycleBinPage> createState() => _RecycleBinPageState();
}

class _RecycleBinPageState extends State<RecycleBinPage> {
  List<CalendarItem> _deletedItems = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _deletedItems = await widget.controller.listDeletedItems();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('加载失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 6),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '回收站',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            TextButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('刷新'),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
        child: Text(
          '已删除的事项会保留在回收站中，可以随时恢复。',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
        child: Text(
          '恢复后事项会重新出现在列表和日历中，并产生正常的同步变更。'
          '重复恢复同一事项是安全的（幂等操作）。',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      Expanded(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _deletedItems.isEmpty
            ? const EmptyState(
                icon: Icons.delete_sweep_outlined,
                title: '回收站为空',
                message: '删除的事项会出现在这里。',
              )
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 96),
                itemCount: _deletedItems.length,
                itemBuilder: (context, index) {
                  final item = _deletedItems[index];
                  return Card(
                    child: ListTile(
                      leading: Icon(
                        item.type == ItemType.event
                            ? Icons.event_outlined
                            : item.type == ItemType.task
                            ? Icons.check_circle_outline
                            : Icons.notes_outlined,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      title: Text(
                        item.title,
                        style: TextStyle(
                          decoration: TextDecoration.lineThrough,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      subtitle: Text(
                        '删除于 ${_formatDeletedAt(context, item.deletedAt)}'
                        ' · ${item.type == ItemType.event
                            ? '日程'
                            : item.type == ItemType.task
                            ? 'Due'
                            : '笔记'}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      trailing: Wrap(
                        spacing: 4,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () => _restore(item),
                            icon: const Icon(Icons.restore_outlined, size: 18),
                            label: const Text('恢复'),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    ],
  );

  Future<void> _restore(CalendarItem item) async {
    try {
      await widget.controller.restoreItem(item);
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('“${item.title}”已恢复')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('恢复失败：$error')));
      }
    }
  }

  String _formatDeletedAt(BuildContext context, DateTime? value) {
    if (value == null) return '未知时间';
    final local = inConfiguredTimezone(value);
    return '${formatMonthDay(context, local)} ${formatTime(context, local)}';
  }
}
