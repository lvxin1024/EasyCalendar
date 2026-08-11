import 'package:flutter/material.dart';

import '../domain/item.dart';
import '../utils/date_formatters.dart';
import '../utils/tag_colors.dart';

class ItemTile extends StatelessWidget {
  const ItemTile({
    super.key,
    required this.item,
    required this.onEdit,
    required this.onDelete,
    this.onToggleCompleted,
    this.highlightOverdue = false,
    this.tagColors = const {},
  });

  final CalendarItem item;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<bool>? onToggleCompleted;
  final bool highlightOverdue;
  final Map<String, int> tagColors;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final completed = item.status == ItemStatus.done;
    final cancelled = item.status == ItemStatus.cancelled;
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE4E7EC))),
      ),
      child: ListTile(
        minTileHeight: 72,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: item.type == ItemType.task
            ? Tooltip(
                message: completed ? '标记为未完成' : '标记为完成',
                child: Checkbox(
                  value: completed,
                  onChanged: onToggleCompleted == null
                      ? null
                      : (value) => onToggleCompleted!(value ?? false),
                ),
              )
            : SizedBox(
                width: 48,
                child: Icon(
                  _typeIcon(item.type),
                  color: item.type == ItemType.event
                      ? colorScheme.primary
                      : colorScheme.secondary,
                ),
              ),
        title: Text(
          item.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            decoration: completed ? TextDecoration.lineThrough : null,
            color: cancelled ? colorScheme.outline : null,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              if (highlightOverdue)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(
                    Icons.error_outline,
                    size: 16,
                    color: colorScheme.error,
                  ),
                ),
              Expanded(
                child: Text.rich(
                  _subtitle(item, tagColors),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        trailing: PopupMenuButton<_ItemAction>(
          tooltip: '更多操作',
          icon: const Icon(Icons.more_vert),
          onSelected: (action) {
            switch (action) {
              case _ItemAction.edit:
                onEdit();
                break;
              case _ItemAction.delete:
                onDelete();
                break;
            }
          },
          itemBuilder: (context) => const [
            PopupMenuItem(
              value: _ItemAction.edit,
              child: ListTile(
                leading: Icon(Icons.edit_outlined),
                title: Text('编辑'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            PopupMenuItem(
              value: _ItemAction.delete,
              child: ListTile(
                leading: Icon(Icons.delete_outline),
                title: Text('删除'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ],
        ),
        onTap: onEdit,
      ),
    );
  }

  static IconData _typeIcon(ItemType type) => switch (type) {
    ItemType.event => Icons.event_outlined,
    ItemType.task => Icons.check_circle_outline,
    ItemType.note => Icons.notes_outlined,
  };

  static TextSpan _subtitle(CalendarItem item, Map<String, int> tagColors) {
    final spans = <InlineSpan>[TextSpan(text: formatSchedule(item))];
    if (item.location != null) {
      spans.add(TextSpan(text: '  ·  ${item.location}'));
    }
    for (final tag in item.tags.take(2)) {
      final color = colorForTag(tag, tagColors);
      spans.add(
        TextSpan(
          text: '  ·  ● $tag',
          style: TextStyle(color: color),
        ),
      );
    }
    return TextSpan(children: spans);
  }
}

enum _ItemAction { edit, delete }
