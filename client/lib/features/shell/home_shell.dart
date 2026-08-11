import 'package:flutter/material.dart';

import '../../application/item_controller.dart';
import '../../config/app_config.dart';
import '../../domain/item.dart';
import '../due/due_page.dart';
import '../editor/item_editor_page.dart';
import '../items/items_page.dart';
import '../settings/settings_page.dart';
import '../today/today_page.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.config,
    required this.controller,
  });

  final AppConfig config;
  final ItemController controller;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _selectedIndex = 0;

  static const _destinations = [
    NavigationDestination(
      icon: Icon(Icons.today_outlined),
      selectedIcon: Icon(Icons.today),
      label: '今天',
    ),
    NavigationDestination(
      icon: Icon(Icons.view_list_outlined),
      selectedIcon: Icon(Icons.view_list),
      label: '全部',
    ),
    NavigationDestination(
      icon: Icon(Icons.check_circle_outline),
      selectedIcon: Icon(Icons.check_circle),
      label: 'Due',
    ),
    NavigationDestination(
      icon: Icon(Icons.settings_outlined),
      selectedIcon: Icon(Icons.settings),
      label: '设置',
    ),
  ];

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      if (widget.controller.loading) {
        return const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        );
      }
      if (!widget.controller.initialized && widget.controller.error != null) {
        return _StartupError(
          error: widget.controller.error!,
          onRetry: widget.controller.initialize,
        );
      }
      return LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 900;
          return Scaffold(
            appBar: wide
                ? null
                : AppBar(
                    title: Text(widget.config.appName),
                    actions: [
                      IconButton(
                        tooltip: '刷新',
                        onPressed: widget.controller.refresh,
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
            body: Row(
              children: [
                if (wide) ...[
                  NavigationRail(
                    extended: constraints.maxWidth >= 1180,
                    minExtendedWidth: 220,
                    selectedIndex: _selectedIndex,
                    onDestinationSelected: _selectDestination,
                    leading: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 20, 12, 28),
                      child: constraints.maxWidth >= 1180
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.calendar_month,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  widget.config.appName,
                                  style: Theme.of(context).textTheme.titleMedium,
                                ),
                              ],
                            )
                          : Tooltip(
                              message: widget.config.appName,
                              child: Icon(
                                Icons.calendar_month,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                    ),
                    destinations: const [
                      NavigationRailDestination(
                        icon: Icon(Icons.today_outlined),
                        selectedIcon: Icon(Icons.today),
                        label: Text('今天'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.view_list_outlined),
                        selectedIcon: Icon(Icons.view_list),
                        label: Text('全部'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.check_circle_outline),
                        selectedIcon: Icon(Icons.check_circle),
                        label: Text('Due'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.settings_outlined),
                        selectedIcon: Icon(Icons.settings),
                        label: Text('设置'),
                      ),
                    ],
                  ),
                  const VerticalDivider(),
                ],
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1100),
                      child: _currentPage(),
                    ),
                  ),
                ),
              ],
            ),
            bottomNavigationBar: wide
                ? null
                : NavigationBar(
                    selectedIndex: _selectedIndex,
                    destinations: _destinations,
                    onDestinationSelected: _selectDestination,
                  ),
            floatingActionButton: _selectedIndex == 3
                ? null
                : FloatingActionButton(
                    tooltip: '新建事项',
                    onPressed: widget.controller.mutating ? null : () => _openEditor(),
                    child: const Icon(Icons.add),
                  ),
          );
        },
      );
    },
  );

  Widget _currentPage() => switch (_selectedIndex) {
    0 => TodayPage(
      controller: widget.controller,
      onEdit: _openEditor,
      onDelete: _confirmDelete,
      onToggleCompleted: _toggleCompleted,
    ),
    1 => ItemsPage(
      controller: widget.controller,
      onEdit: _openEditor,
      onDelete: _confirmDelete,
      onToggleCompleted: _toggleCompleted,
    ),
    2 => DuePage(
      controller: widget.controller,
      onEdit: _openEditor,
      onDelete: _confirmDelete,
      onToggleCompleted: _toggleCompleted,
    ),
    _ => SettingsPage(config: widget.config, controller: widget.controller),
  };

  void _selectDestination(int value) => setState(() => _selectedIndex = value);

  Future<void> _openEditor([CalendarItem? item]) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => ItemEditorPage(
          config: widget.config,
          controller: widget.controller,
          item: item,
        ),
      ),
    );
  }

  Future<void> _confirmDelete(CalendarItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除事项'),
        content: Text('确定删除“${item.title}”吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.delete_outline),
            label: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.controller.deleteItem(item);
    } catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<void> _toggleCompleted(CalendarItem item, bool completed) async {
    try {
      await widget.controller.setTaskCompleted(item, completed: completed);
    } catch (error) {
      if (mounted) _showError(error);
    }
  }

  void _showError(Object error) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error.toString())),
    );
  }
}

class _StartupError extends StatelessWidget {
  const _StartupError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.storage_outlined,
                size: 40,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                '无法打开本地数据库',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                error.toString(),
                textAlign: TextAlign.center,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
