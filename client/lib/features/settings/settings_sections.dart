part of 'settings_page.dart';

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.4,
      ),
    ),
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
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      border: Border(
        bottom: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
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
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(
            bottom: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
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

class _WidgetQuoteSection extends StatelessWidget {
  const _WidgetQuoteSection({
    required this.quotes,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
  });

  final List<String> quotes;
  final VoidCallback? onAdd;
  final ValueChanged<int> onEdit;
  final ValueChanged<int> onDelete;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: 24),
      Row(
        children: [
          const Expanded(child: _SectionLabel(label: 'Due 小组件文案')),
          IconButton(
            tooltip: quotes.length >= 10 ? '最多 10 句' : '添加文案',
            onPressed: onAdd,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      if (quotes.isEmpty)
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text('Due 清空后显示默认文案；最多可配置 10 句。'),
        ),
      for (var index = 0; index < quotes.length; index++)
        ListTile(
          leading: const Icon(Icons.format_quote_outlined),
          title: Text(
            quotes[index],
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => onEdit(index),
          trailing: IconButton(
            tooltip: '删除',
            onPressed: () => onDelete(index),
            icon: const Icon(Icons.delete_outline),
          ),
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
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
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
