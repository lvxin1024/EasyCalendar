import 'package:flutter/material.dart';

import '../../application/item_controller.dart';
import '../../config/app_config.dart';
import '../../data/transfer_models.dart';
import '../../domain/item.dart';
import '../../widget/widget_deep_link_controller.dart';
import '../../widgets/glass_surface.dart';
import '../calendar/calendar_navigation_controller.dart';
import '../calendar/calendar_page.dart';
import '../due/due_page.dart';
import '../assistant/assistant_page.dart';
import '../editor/item_editor_page.dart';
import '../items/items_page.dart';
import '../settings/settings_page.dart';
import '../subscriptions/subscriptions_page.dart';

@visibleForTesting
const mobilePrimaryDestinationIndexes = <int>[0, 1, 2, 4];

@visibleForTesting
int mobileNavigationIndexForDestination(int destinationIndex) {
  final index = mobilePrimaryDestinationIndexes.indexOf(destinationIndex);
  return index >= 0 ? index : mobilePrimaryDestinationIndexes.length;
}

@visibleForTesting
int? destinationIndexForMobileNavigation(int navigationIndex) =>
    navigationIndex >= 0 &&
        navigationIndex < mobilePrimaryDestinationIndexes.length
    ? mobilePrimaryDestinationIndexes[navigationIndex]
    : null;

class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.config,
    required this.controller,
    required this.widgetDeepLinks,
  });

  final AppConfig config;
  final ItemController controller;
  final WidgetDeepLinkController widgetDeepLinks;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _selectedIndex = 0;
  late final CalendarNavigationController _calendarNavigation;
  final _calendarDestinationTaps = CalendarDestinationTapTracker();

  @override
  void initState() {
    super.initState();
    _calendarNavigation = CalendarNavigationController();
    widget.widgetDeepLinks.addListener(_handleWidgetDeepLink);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _handleWidgetDeepLink(),
    );
  }

  @override
  void didUpdateWidget(HomeShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.widgetDeepLinks == widget.widgetDeepLinks) return;
    oldWidget.widgetDeepLinks.removeListener(_handleWidgetDeepLink);
    widget.widgetDeepLinks.addListener(_handleWidgetDeepLink);
  }

  @override
  void dispose() {
    widget.widgetDeepLinks.removeListener(_handleWidgetDeepLink);
    _calendarNavigation.dispose();
    super.dispose();
  }

  static const _destinationData = [
    (
      icon: Icons.calendar_view_week_outlined,
      selectedIcon: Icons.calendar_view_week,
      label: '日程',
    ),
    (
      icon: Icons.view_list_outlined,
      selectedIcon: Icons.view_list,
      label: '全部',
    ),
    (
      icon: Icons.check_circle_outline,
      selectedIcon: Icons.check_circle,
      label: 'Due',
    ),
    (icon: Icons.link_outlined, selectedIcon: Icons.link, label: '订阅'),
    (
      icon: Icons.auto_awesome_outlined,
      selectedIcon: Icons.auto_awesome,
      label: '助手',
    ),
    (icon: Icons.settings_outlined, selectedIcon: Icons.settings, label: '设置'),
  ];

  List<NavigationDestination> get _mobileDestinations => [
    for (final index in mobilePrimaryDestinationIndexes)
      NavigationDestination(
        icon: _navGlyph(index, selected: false),
        selectedIcon: _navGlyph(index, selected: true),
        label: _destinationData[index].label,
      ),
    NavigationDestination(
      icon: _moreNavGlyph(selected: false),
      selectedIcon: _moreNavGlyph(selected: true),
      label: '更多',
    ),
  ];

  Widget _navGlyph(int index, {required bool selected}) {
    final data = _destinationData[index];
    final colorScheme = Theme.of(context).colorScheme;
    return _ColoredNavGlyph(
      icon: selected ? data.selectedIcon : data.icon,
      color: selected ? colorScheme.primary : colorScheme.onSurfaceVariant,
      background: colorScheme.primaryContainer,
      selected: selected,
    );
  }

  Widget _moreNavGlyph({required bool selected}) {
    final colorScheme = Theme.of(context).colorScheme;
    return _ColoredNavGlyph(
      icon: selected ? Icons.more_horiz : Icons.more_horiz_outlined,
      color: selected ? colorScheme.primary : colorScheme.onSurfaceVariant,
      background: colorScheme.primaryContainer,
      selected: selected,
    );
  }

  List<NavigationRailDestination> get _railDestinations => [
    for (var index = 0; index < _destinationData.length; index++)
      NavigationRailDestination(
        icon: _navGlyph(index, selected: false),
        selectedIcon: _navGlyph(index, selected: true),
        label: Text(_destinationData[index].label),
      ),
  ];

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      if (widget.controller.loading) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      if (!widget.controller.initialized && widget.controller.error != null) {
        return _StartupError(controller: widget.controller);
      }
      return LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 900;
          return Scaffold(
            appBar: null,
            extendBody: true,
            body: SafeArea(
              child: Row(
                children: [
                  if (wide) ...[
                    GlassSurface(
                      borderRadius: BorderRadius.zero,
                      tint: Theme.of(
                        context,
                      ).colorScheme.surface.withAlpha(194),
                      borderColor: Theme.of(
                        context,
                      ).colorScheme.outlineVariant.withAlpha(180),
                      child: NavigationRail(
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
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      widget.config.appName,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleMedium,
                                    ),
                                  ],
                                )
                              : Tooltip(
                                  message: widget.config.appName,
                                  child: Icon(
                                    Icons.calendar_month,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                  ),
                                ),
                        ),
                        destinations: _railDestinations,
                      ),
                    ),
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
            ),
            bottomNavigationBar: wide
                ? null
                : GlassSurface(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(24),
                    ),
                    child: NavigationBar(
                      selectedIndex: mobileNavigationIndexForDestination(
                        _selectedIndex,
                      ),
                      destinations: _mobileDestinations,
                      onDestinationSelected: _selectMobileDestination,
                    ),
                  ),
            floatingActionButton: _selectedIndex >= 3
                ? null
                : FloatingActionButton(
                    tooltip: '新建事项',
                    onPressed: widget.controller.mutating
                        ? null
                        : () => _openEditor(),
                    child: const Icon(Icons.add),
                  ),
          );
        },
      );
    },
  );

  Widget _currentPage() => switch (_selectedIndex) {
    0 => CalendarPage(
      controller: widget.controller,
      navigation: _calendarNavigation,
      onEdit: _openEditor,
      onDelete: _confirmDelete,
      onCreateTimedEvent: (startAt) =>
          _openEditor(null, startAt, startAt.add(const Duration(hours: 1))),
      onSync: _syncNow,
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
    3 => SubscriptionsPage(controller: widget.controller),
    4 => AssistantPage(config: widget.config, controller: widget.controller),
    _ => SettingsPage(config: widget.config, controller: widget.controller),
  };

  void _selectDestination(int value) {
    if (_calendarDestinationTaps.register(
      value,
      selectedIndex: _selectedIndex,
      now: DateTime.now(),
    )) {
      _calendarNavigation.goToToday();
      return;
    }
    if (_selectedIndex == value) return;
    setState(() => _selectedIndex = value);
  }

  Future<void> _selectMobileDestination(int navigationIndex) async {
    final destinationIndex = destinationIndexForMobileNavigation(
      navigationIndex,
    );
    if (destinationIndex != null) {
      _selectDestination(destinationIndex);
      return;
    }
    final selected = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  '更多',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              ListTile(
                leading: const Icon(Icons.link_outlined),
                title: const Text('订阅'),
                selected: _selectedIndex == 3,
                onTap: () => Navigator.pop(context, 3),
              ),
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('设置'),
                selected: _selectedIndex == 5,
                onTap: () => Navigator.pop(context, 5),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected != null && mounted) _selectDestination(selected);
  }

  Future<void> _handleWidgetDeepLink() async {
    final target = widget.widgetDeepLinks.takePendingTarget();
    if (target == null || !mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    if (target.kind == WidgetDeepLinkKind.today) {
      _calendarNavigation.goToToday(useDayView: true);
      setState(() => _selectedIndex = 0);
      return;
    }
    if (target.kind == WidgetDeepLinkKind.due) {
      setState(() => _selectedIndex = 2);
      return;
    }
    CalendarItem? item;
    for (final candidate in widget.controller.items) {
      if (candidate.id == target.itemId) {
        item = candidate;
        break;
      }
    }
    if (item == null) {
      setState(() => _selectedIndex = 1);
      _showError('该事项已不存在。');
      return;
    }
    if (target.kind == WidgetDeepLinkKind.complete) {
      if (item.type == ItemType.task && item.status == ItemStatus.todo) {
        try {
          await widget.controller.setTaskCompleted(item, completed: true);
        } catch (error) {
          if (mounted) _showError('完成事项失败：$error');
        }
      }
      return;
    }
    await _openEditor(item);
  }

  Future<void> _openEditor([
    CalendarItem? item,
    DateTime? initialStartAt,
    DateTime? initialEndAt,
  ]) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => ItemEditorPage(
          config: widget.config,
          controller: widget.controller,
          item: item,
          initialStartAt: initialStartAt,
          initialEndAt: initialEndAt,
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

  Future<void> _syncNow() async {
    try {
      await widget.controller.synchronizeNow();
    } catch (error) {
      if (mounted) _showError(error);
    }
  }

  void _showError(Object error) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error.toString())));
  }
}

class _ColoredNavGlyph extends StatelessWidget {
  const _ColoredNavGlyph({
    required this.icon,
    required this.color,
    required this.background,
    required this.selected,
  });

  final IconData icon;
  final Color color;
  final Color background;
  final bool selected;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 180),
    width: 44,
    height: 32,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: selected ? background : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Icon(icon, size: 21, color: color),
  );
}

class CalendarDestinationTapTracker {
  CalendarDestinationTapTracker({
    this.destinationIndex = 0,
    this.doubleTapWindow = const Duration(milliseconds: 360),
  });

  final int destinationIndex;
  final Duration doubleTapWindow;
  DateTime? _lastTapAt;

  bool register(
    int value, {
    required int selectedIndex,
    required DateTime now,
  }) {
    final previous = _lastTapAt;
    if (value == destinationIndex &&
        selectedIndex == destinationIndex &&
        previous != null &&
        now.difference(previous) <= doubleTapWindow) {
      _lastTapAt = null;
      return true;
    }
    _lastTapAt = value == destinationIndex ? now : null;
    return false;
  }
}

class _StartupError extends StatefulWidget {
  const _StartupError({required this.controller});

  final ItemController controller;

  @override
  State<_StartupError> createState() => _StartupErrorState();
}

class _StartupErrorState extends State<_StartupError> {
  bool _restoring = false;

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
                '无法启动 EasyCalendar',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                widget.controller.error.toString(),
                textAlign: TextAlign.center,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: _restoring ? null : widget.controller.initialize,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重试'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _restoring ? null : _chooseBackup,
                    icon: const Icon(Icons.settings_backup_restore),
                    label: const Text('从恢复点恢复'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Future<void> _chooseBackup() async {
    List<LocalDatabaseBackup> backups;
    try {
      backups = await widget.controller.listLocalDatabaseBackups();
    } catch (error) {
      _showError('无法读取恢复点：$error');
      return;
    }
    if (!mounted) return;
    if (backups.isEmpty) {
      _showError('没有可用的本地恢复点');
      return;
    }
    final selected = await showDialog<LocalDatabaseBackup>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('选择恢复点'),
        content: SizedBox(
          width: 480,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: backups.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final backup = backups[index];
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.restore_page_outlined),
                title: Text(_reasonLabel(backup.reason)),
                subtitle: Text(
                  '${backup.createdAt.toLocal()} · schema v${backup.schemaVersion}',
                ),
                onTap: () => Navigator.pop(context, backup),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (selected == null) return;
    setState(() => _restoring = true);
    try {
      await widget.controller.restoreLocalDatabaseBackup(selected.path);
    } catch (error) {
      if (mounted) _showError('恢复失败：$error');
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  static String _reasonLabel(LocalBackupReason reason) => switch (reason) {
    LocalBackupReason.migration => '升级前自动恢复点',
    LocalBackupReason.manual => '手动恢复点',
    LocalBackupReason.preRestore => '恢复操作前的状态',
  };
}
