import '../ai/ai_provider.dart';

enum ItemType { event, task, note }

enum ItemStatus { todo, done, cancelled }

class ItemDraft {
  const ItemDraft({
    required this.type,
    required this.title,
    this.body,
    this.startAt,
    this.endAt,
    this.dueAt,
    required this.timezone,
    this.allDay = false,
    this.location,
    this.status = ItemStatus.todo,
    this.priority,
    this.reminderEnabled = false,
    this.reminderMinutes = 30,
    this.tags = const [],
  });

  final ItemType type;
  final String title;
  final String? body;
  final DateTime? startAt;
  final DateTime? endAt;
  final DateTime? dueAt;
  final String timezone;
  final bool allDay;
  final String? location;
  final ItemStatus status;
  final int? priority;
  final bool reminderEnabled;
  final int reminderMinutes;
  final List<String> tags;
}

class CalendarItem {
  const CalendarItem({
    required this.id,
    required this.collectionId,
    required this.type,
    required this.title,
    this.body,
    this.startAt,
    this.endAt,
    this.dueAt,
    required this.timezone,
    required this.allDay,
    this.location,
    required this.status,
    this.priority,
    required this.reminderEnabled,
    required this.reminderMinutes,
    required this.tags,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
    required this.version,
  });

  final String id;
  final String collectionId;
  final ItemType type;
  final String title;
  final String? body;
  final DateTime? startAt;
  final DateTime? endAt;
  final DateTime? dueAt;
  final String timezone;
  final bool allDay;
  final String? location;
  final ItemStatus status;
  final int? priority;
  final bool reminderEnabled;
  final int reminderMinutes;
  final List<String> tags;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;
  final int version;

  DateTime? get scheduleAt => type == ItemType.event ? startAt : dueAt;

  bool get isDeleted => deletedAt != null;

  ItemDraft toDraft() => ItemDraft(
    type: type,
    title: title,
    body: body,
    startAt: startAt,
    endAt: endAt,
    dueAt: dueAt,
    timezone: timezone,
    allDay: allDay,
    location: location,
    status: status,
    priority: priority,
    reminderEnabled: reminderEnabled,
    reminderMinutes: reminderMinutes,
    tags: tags,
  );
}

class ClientPreferences {
  const ClientPreferences({
    required this.apiUrl,
    required this.syncEnabled,
    required this.notificationsEnabled,
    this.windowOpacity = 1,
    this.windowAlwaysOnTop = false,
    this.assistantEnabled = false,
    this.aiProviders = const [],
  });

  final String apiUrl;
  final bool syncEnabled;
  final bool notificationsEnabled;
  final double windowOpacity;
  final bool windowAlwaysOnTop;
  final bool assistantEnabled;
  final List<AiProviderConfig> aiProviders;

  ClientPreferences copyWith({
    String? apiUrl,
    bool? syncEnabled,
    bool? notificationsEnabled,
    double? windowOpacity,
    bool? windowAlwaysOnTop,
    bool? assistantEnabled,
    List<AiProviderConfig>? aiProviders,
  }) => ClientPreferences(
    apiUrl: apiUrl ?? this.apiUrl,
    syncEnabled: syncEnabled ?? this.syncEnabled,
    notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
    windowOpacity: windowOpacity ?? this.windowOpacity,
    windowAlwaysOnTop: windowAlwaysOnTop ?? this.windowAlwaysOnTop,
    assistantEnabled: assistantEnabled ?? this.assistantEnabled,
    aiProviders: aiProviders ?? this.aiProviders,
  );
}
