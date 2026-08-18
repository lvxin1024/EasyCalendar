import '../ai/ai_provider.dart';
import 'recurrence.dart';

enum ItemType { event, task, note }

enum ItemStatus { todo, done, cancelled }

class ItemDraft {
  const ItemDraft({
    this.collectionId,
    required this.type,
    required this.title,
    this.body,
    this.startAt,
    this.endAt,
    this.dueAt,
    this.recurrence,
    required this.timezone,
    this.allDay = false,
    this.location,
    this.status = ItemStatus.todo,
    this.priority,
    this.reminderEnabled = false,
    this.reminderMinutes = 30,
    this.tags = const [],
  });

  final String? collectionId;
  final ItemType type;
  final String title;
  final String? body;
  final DateTime? startAt;
  final DateTime? endAt;
  final DateTime? dueAt;
  final RecurrenceRule? recurrence;
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
    this.recurrence,
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
  final RecurrenceRule? recurrence;
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
    collectionId: collectionId,
    type: type,
    title: title,
    body: body,
    startAt: startAt,
    endAt: endAt,
    dueAt: dueAt,
    recurrence: recurrence,
    timezone: timezone,
    allDay: allDay,
    location: location,
    status: status,
    priority: priority,
    reminderEnabled: reminderEnabled,
    reminderMinutes: reminderMinutes,
    tags: tags,
  );

  CalendarItem copyWith({
    String? id,
    DateTime? startAt,
    DateTime? endAt,
    RecurrenceRule? recurrence,
  }) => CalendarItem(
    id: id ?? this.id,
    collectionId: collectionId,
    type: type,
    title: title,
    body: body,
    startAt: startAt ?? this.startAt,
    endAt: endAt ?? this.endAt,
    dueAt: dueAt,
    recurrence: recurrence ?? this.recurrence,
    timezone: timezone,
    allDay: allDay,
    location: location,
    status: status,
    priority: priority,
    reminderEnabled: reminderEnabled,
    reminderMinutes: reminderMinutes,
    tags: tags,
    createdAt: createdAt,
    updatedAt: updatedAt,
    deletedAt: deletedAt,
    version: version,
  );
}

class CalendarCollection {
  const CalendarCollection({
    required this.id,
    required this.name,
    required this.kind,
    this.color,
    required this.readonly,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
    required this.version,
  });

  final String id;
  final String name;
  final String kind;
  final int? color;
  final bool readonly;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;
  final int version;
}

class ClientPreferences {
  const ClientPreferences({
    required this.apiUrl,
    this.deviceId = 'my-easycalendar-client',
    this.deviceName = '',
    this.defaultCollectionId = 'collection_local',
    this.defaultCollectionName = '我的日程',
    required this.syncEnabled,
    required this.notificationsEnabled,
    this.windowOpacity = 1,
    this.windowAlwaysOnTop = false,
    this.assistantEnabled = false,
    this.aiProviders = const [],
    this.tagColors = const {},
  });

  final String apiUrl;
  final String deviceId;
  final String deviceName;
  final String defaultCollectionId;
  final String defaultCollectionName;
  final bool syncEnabled;
  final bool notificationsEnabled;
  final double windowOpacity;
  final bool windowAlwaysOnTop;
  final bool assistantEnabled;
  final List<AiProviderConfig> aiProviders;
  final Map<String, int> tagColors;

  ClientPreferences copyWith({
    String? apiUrl,
    String? deviceId,
    String? deviceName,
    String? defaultCollectionId,
    String? defaultCollectionName,
    bool? syncEnabled,
    bool? notificationsEnabled,
    double? windowOpacity,
    bool? windowAlwaysOnTop,
    bool? assistantEnabled,
    List<AiProviderConfig>? aiProviders,
    Map<String, int>? tagColors,
  }) => ClientPreferences(
    apiUrl: apiUrl ?? this.apiUrl,
    deviceId: deviceId ?? this.deviceId,
    deviceName: deviceName ?? this.deviceName,
    defaultCollectionId: defaultCollectionId ?? this.defaultCollectionId,
    defaultCollectionName: defaultCollectionName ?? this.defaultCollectionName,
    syncEnabled: syncEnabled ?? this.syncEnabled,
    notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
    windowOpacity: windowOpacity ?? this.windowOpacity,
    windowAlwaysOnTop: windowAlwaysOnTop ?? this.windowAlwaysOnTop,
    assistantEnabled: assistantEnabled ?? this.assistantEnabled,
    aiProviders: aiProviders ?? this.aiProviders,
    tagColors: tagColors ?? this.tagColors,
  );
}
