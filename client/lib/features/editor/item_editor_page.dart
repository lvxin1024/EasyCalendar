import 'package:flutter/material.dart';

import '../../application/item_controller.dart';
import '../../config/app_config.dart';
import '../../domain/item.dart';
import '../../utils/date_formatters.dart';
import '../../utils/configured_time.dart';

class ItemEditorPage extends StatefulWidget {
  const ItemEditorPage({
    super.key,
    required this.config,
    required this.controller,
    this.item,
  });

  final AppConfig config;
  final ItemController controller;
  final CalendarItem? item;

  @override
  State<ItemEditorPage> createState() => _ItemEditorPageState();
}

class _ItemEditorPageState extends State<ItemEditorPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _bodyController;
  late final TextEditingController _locationController;
  late final TextEditingController _tagsController;
  late ItemType _type;
  late ItemStatus _status;
  late bool _allDay;
  late bool _reminderEnabled;
  late int _reminderMinutes;
  int? _priority;
  DateTime? _startAt;
  DateTime? _endAt;
  DateTime? _dueAt;

  bool get _editing => widget.item != null;

  @override
  void initState() {
    super.initState();
    final item = widget.item;
    final now = configuredNow();
    _type = item?.type ?? ItemType.event;
    _status = item?.status ?? ItemStatus.todo;
    _allDay = item?.allDay ?? false;
    _reminderEnabled = item?.reminderEnabled ?? false;
    _reminderMinutes = item?.reminderMinutes ?? 30;
    _priority = item?.priority;
    _startAt = item?.startAt ?? now.add(const Duration(hours: 1));
    _endAt = item?.endAt ?? now.add(const Duration(hours: 2));
    _dueAt = item?.dueAt;
    _titleController = TextEditingController(text: item?.title ?? '');
    _bodyController = TextEditingController(text: item?.body ?? '');
    _locationController = TextEditingController(text: item?.location ?? '');
    _tagsController = TextEditingController(text: item?.tags.join(', ') ?? '');
  }

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    _locationController.dispose();
    _tagsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(_editing ? '编辑事项' : '新建事项'),
      actions: [
        if (_editing)
          IconButton(
            tooltip: '删除',
            onPressed: widget.controller.mutating ? null : _delete,
            icon: const Icon(Icons.delete_outline),
          ),
      ],
    ),
    body: SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 112),
              children: [
                SegmentedButton<ItemType>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: ItemType.event,
                      icon: Icon(Icons.event_outlined),
                      label: Text('日程'),
                    ),
                    ButtonSegment(
                      value: ItemType.task,
                      icon: Icon(Icons.check_circle_outline),
                      label: Text('Due'),
                    ),
                    ButtonSegment(
                      value: ItemType.note,
                      icon: Icon(Icons.notes_outlined),
                      label: Text('笔记'),
                    ),
                  ],
                  selected: {_type},
                  onSelectionChanged: (values) => _changeType(values.first),
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: _titleController,
                  autofocus: !_editing,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '标题',
                    prefixIcon: Icon(Icons.title),
                  ),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? '请输入标题'
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _bodyController,
                  minLines: 3,
                  maxLines: 7,
                  decoration: const InputDecoration(
                    labelText: '备注',
                    alignLabelWithHint: true,
                    prefixIcon: Icon(Icons.subject),
                  ),
                ),
                if (_type == ItemType.event) ..._eventFields(),
                if (_type == ItemType.task) ..._taskFields(),
                if (_type != ItemType.note) ...[
                  const SizedBox(height: 22),
                  Text('提醒', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启用提醒'),
                    secondary: const Icon(Icons.notifications_outlined),
                    value: _reminderEnabled,
                    onChanged: (value) =>
                        setState(() => _reminderEnabled = value),
                  ),
                  if (_reminderEnabled)
                    DropdownButtonFormField<int>(
                      initialValue: _reminderMinutes,
                      decoration: const InputDecoration(
                        labelText: '提前时间',
                        prefixIcon: Icon(Icons.alarm),
                      ),
                      items: const [
                        DropdownMenuItem(value: 0, child: Text('准时')),
                        DropdownMenuItem(value: 5, child: Text('提前 5 分钟')),
                        DropdownMenuItem(value: 15, child: Text('提前 15 分钟')),
                        DropdownMenuItem(value: 30, child: Text('提前 30 分钟')),
                        DropdownMenuItem(value: 60, child: Text('提前 1 小时')),
                        DropdownMenuItem(value: 1440, child: Text('提前 1 天')),
                      ],
                      onChanged: (value) =>
                          setState(() => _reminderMinutes = value ?? 30),
                    ),
                ],
                const SizedBox(height: 22),
                Text('整理', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _tagsController,
                  decoration: const InputDecoration(
                    labelText: '标签',
                    hintText: '工作, 项目',
                    prefixIcon: Icon(Icons.sell_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<ItemStatus>(
                  initialValue: _status,
                  decoration: const InputDecoration(
                    labelText: '状态',
                    prefixIcon: Icon(Icons.flag_outlined),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: ItemStatus.todo,
                      child: Text('待处理'),
                    ),
                    DropdownMenuItem(
                      value: ItemStatus.done,
                      child: Text('已完成'),
                    ),
                    DropdownMenuItem(
                      value: ItemStatus.cancelled,
                      child: Text('已取消'),
                    ),
                  ],
                  onChanged: (value) => setState(() => _status = value!),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
    bottomNavigationBar: SafeArea(
      minimum: const EdgeInsets.fromLTRB(20, 10, 20, 16),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: widget.controller.mutating ? null : _save,
              icon: const Icon(Icons.save_outlined),
              label: Text(_editing ? '保存修改' : '创建事项'),
            ),
          ),
        ),
      ),
    ),
  );

  List<Widget> _eventFields() => [
    const SizedBox(height: 22),
    Text('时间', style: Theme.of(context).textTheme.titleSmall),
    const SizedBox(height: 8),
    SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('全天'),
      secondary: const Icon(Icons.wb_sunny_outlined),
      value: _allDay,
      onChanged: (value) => setState(() => _allDay = value),
    ),
    _DateTimeField(
      label: '开始',
      value: _startAt,
      allDay: _allDay,
      allowClear: false,
      onChanged: (value) => setState(() {
        if (value == null) return;
        final oldStart = _startAt;
        _startAt = value;
        if (oldStart != null && _endAt != null) {
          _endAt = value.add(_endAt!.difference(oldStart));
        }
      }),
    ),
    const SizedBox(height: 10),
    _DateTimeField(
      label: '结束',
      value: _endAt,
      allDay: _allDay,
      allowClear: true,
      onChanged: (value) => setState(() => _endAt = value),
    ),
    const SizedBox(height: 12),
    TextFormField(
      controller: _locationController,
      decoration: const InputDecoration(
        labelText: '地点',
        prefixIcon: Icon(Icons.location_on_outlined),
      ),
    ),
  ];

  List<Widget> _taskFields() => [
    const SizedBox(height: 22),
    Text('Due', style: Theme.of(context).textTheme.titleSmall),
    const SizedBox(height: 8),
    _DateTimeField(
      label: '截止时间',
      value: _dueAt,
      allDay: false,
      allowClear: true,
      onChanged: (value) => setState(() => _dueAt = value),
    ),
    const SizedBox(height: 12),
    DropdownButtonFormField<int>(
      initialValue: _priority ?? 0,
      decoration: const InputDecoration(
        labelText: '优先级',
        prefixIcon: Icon(Icons.low_priority),
      ),
      items: const [
        DropdownMenuItem(value: 0, child: Text('未设置')),
        DropdownMenuItem(value: 1, child: Text('低')),
        DropdownMenuItem(value: 2, child: Text('普通')),
        DropdownMenuItem(value: 3, child: Text('高')),
      ],
      onChanged: (value) => setState(
        () => _priority = value == null || value == 0 ? null : value,
      ),
    ),
  ];

  void _changeType(ItemType value) {
    setState(() {
      _type = value;
      if (value == ItemType.event && _startAt == null) {
        _startAt = configuredNow().add(const Duration(hours: 1));
        _endAt = _startAt!.add(const Duration(hours: 1));
      }
      if (value == ItemType.task && _dueAt == null) {
        _dueAt = configuredNow().add(const Duration(days: 1));
      }
    });
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_type == ItemType.event && _startAt == null) {
      _showError('请选择开始时间');
      return;
    }
    if (_type == ItemType.event &&
        _startAt != null &&
        _endAt != null &&
        _endAt!.isBefore(_startAt!)) {
      _showError('结束时间不能早于开始时间');
      return;
    }
    final startAt = _type == ItemType.event && _allDay && _startAt != null
        ? configuredDateTime(
            year: _startAt!.year,
            month: _startAt!.month,
            day: _startAt!.day,
          )
        : _startAt;
    final endAt = _type == ItemType.event && _allDay && _endAt != null
        ? configuredDateTime(
            year: _endAt!.year,
            month: _endAt!.month,
            day: _endAt!.day,
          )
        : _endAt;
    final draft = ItemDraft(
      type: _type,
      title: _titleController.text,
      body: _bodyController.text,
      startAt: _type == ItemType.event ? startAt : null,
      endAt: _type == ItemType.event ? endAt : null,
      dueAt: _type == ItemType.task ? _dueAt : null,
      timezone: widget.config.timezone,
      allDay: _type == ItemType.event && _allDay,
      location: _type == ItemType.event ? _locationController.text : null,
      status: _status,
      priority: _type == ItemType.task ? _priority : null,
      reminderEnabled: _type != ItemType.note && _reminderEnabled,
      reminderMinutes: _reminderMinutes,
      tags: _tagsController.text.split(','),
    );
    try {
      await widget.controller.saveItem(current: widget.item, draft: draft);
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) _showError(error.toString());
    }
  }

  Future<void> _delete() async {
    final item = widget.item;
    if (item == null) return;
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
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.controller.deleteItem(item);
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) _showError(error.toString());
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}

class _DateTimeField extends StatelessWidget {
  const _DateTimeField({
    required this.label,
    required this.value,
    required this.allDay,
    required this.allowClear,
    required this.onChanged,
  });

  final String label;
  final DateTime? value;
  final bool allDay;
  final bool allowClear;
  final ValueChanged<DateTime?> onChanged;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final clearButton = allowClear && value != null
          ? IconButton(
              tooltip: '清除时间',
              visualDensity: VisualDensity.compact,
              onPressed: () => onChanged(null),
              icon: const Icon(Icons.close),
            )
          : null;
      if (constraints.maxWidth < 430) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                if (clearButton != null) clearButton,
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(child: _dateButton(context)),
                if (!allDay) ...[
                  const SizedBox(width: 8),
                  Expanded(child: _timeButton(context)),
                ],
              ],
            ),
          ],
        );
      }
      return Row(
        children: [
          SizedBox(
            width: 52,
            child: Text(label, style: Theme.of(context).textTheme.labelLarge),
          ),
          Expanded(child: _dateButton(context)),
          if (!allDay) ...[
            const SizedBox(width: 8),
            SizedBox(width: 118, child: _timeButton(context)),
          ],
          if (clearButton != null) clearButton,
        ],
      );
    },
  );

  Widget _dateButton(BuildContext context) => OutlinedButton.icon(
    icon: const Icon(Icons.calendar_today_outlined),
    label: Text(
      value == null ? '选择日期' : formatDate(value!),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    onPressed: () => _pickDate(context),
  );

  Widget _timeButton(BuildContext context) => OutlinedButton.icon(
    icon: const Icon(Icons.schedule),
    label: Text(value == null ? '--:--' : formatTime(value!)),
    onPressed: value == null ? null : () => _pickTime(context),
  );

  Future<void> _pickDate(BuildContext context) async {
    final now = configuredNow();
    final selected = await showDatePicker(
      context: context,
      initialDate: value ?? now,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 15),
    );
    if (selected == null) return;
    final time = value == null
        ? TimeOfDay.fromDateTime(configuredNow())
        : TimeOfDay.fromDateTime(value!);
    onChanged(
      configuredDateTime(
        year: selected.year,
        month: selected.month,
        day: selected.day,
        hour: time.hour,
        minute: time.minute,
      ),
    );
  }

  Future<void> _pickTime(BuildContext context) async {
    final current = value;
    if (current == null) return;
    final selected = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
    );
    if (selected == null) return;
    onChanged(
      configuredDateTime(
        year: current.year,
        month: current.month,
        day: current.day,
        hour: selected.hour,
        minute: selected.minute,
      ),
    );
  }
}
