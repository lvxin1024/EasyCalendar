import SwiftUI
import WidgetKit

private enum WidgetSnapshotStore {
  static let appGroup = "group.io.easycalendar.easyCalendar"
  static let relativePath = "widget/snapshot.json"

  enum LoadResult {
    case snapshot(EasyCalendarWidgetSnapshot)
    case missing
    case invalid
  }

  static func load() -> LoadResult {
    guard let container = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroup
    ) else {
      return .invalid
    }
    let url = container.appendingPathComponent(relativePath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return .missing
    }
    do {
      let data = try Data(contentsOf: url)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return .snapshot(try decoder.decode(EasyCalendarWidgetSnapshot.self, from: data))
    } catch {
      return .invalid
    }
  }
}

struct EasyCalendarWidgetItem: Codable, Identifiable {
  let id: String
  let type: String
  let title: String
  let startAt: Date?
  let endAt: Date?
  let dueAt: Date?
  let location: String?
  let status: String
  let version: Int

  enum CodingKeys: String, CodingKey {
    case id
    case type
    case title
    case startAt = "start_at"
    case endAt = "end_at"
    case dueAt = "due_at"
    case location
    case status
    case version
  }

  var scheduleDate: Date? { type == "task" ? dueAt : startAt }
}

struct EasyCalendarWidgetSnapshot: Codable {
  let schemaVersion: Int
  let generatedAt: Date
  let timezone: String
  let version: Int
  let todayEvents: [EasyCalendarWidgetItem]
  let upcomingEvents: [EasyCalendarWidgetItem]
  let dueItems: [EasyCalendarWidgetItem]

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case generatedAt = "generated_at"
    case timezone
    case version
    case todayEvents = "today_events"
    case upcomingEvents = "upcoming_events"
    case dueItems = "due_items"
  }

  init(
    schemaVersion: Int = 1,
    generatedAt: Date = Date(),
    timezone: String = "Asia/Shanghai",
    version: Int = 0,
    todayEvents: [EasyCalendarWidgetItem] = [],
    upcomingEvents: [EasyCalendarWidgetItem] = [],
    dueItems: [EasyCalendarWidgetItem] = []
  ) {
    self.schemaVersion = schemaVersion
    self.generatedAt = generatedAt
    self.timezone = timezone
    self.version = version
    self.todayEvents = todayEvents
    self.upcomingEvents = upcomingEvents
    self.dueItems = dueItems
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    generatedAt = try container.decode(Date.self, forKey: .generatedAt)
    timezone = try container.decode(String.self, forKey: .timezone)
    version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
    todayEvents = try container.decodeIfPresent([EasyCalendarWidgetItem].self, forKey: .todayEvents) ?? []
    upcomingEvents = try container.decodeIfPresent([EasyCalendarWidgetItem].self, forKey: .upcomingEvents) ?? []
    dueItems = try container.decodeIfPresent([EasyCalendarWidgetItem].self, forKey: .dueItems) ?? []
  }
}

struct EasyCalendarWidgetEntry: TimelineEntry {
  let date: Date
  let snapshot: EasyCalendarWidgetSnapshot
  let hasError: Bool

  static let placeholder = EasyCalendarWidgetEntry(
    date: Date(),
    snapshot: EasyCalendarWidgetSnapshot(),
    hasError: false
  )

  static let error = EasyCalendarWidgetEntry(
    date: Date(),
    snapshot: EasyCalendarWidgetSnapshot(),
    hasError: true
  )
}

struct EasyCalendarWidgetProvider: TimelineProvider {
  func placeholder(in _: Context) -> EasyCalendarWidgetEntry {
    .placeholder
  }

  func getSnapshot(in _: Context, completion: @escaping (EasyCalendarWidgetEntry) -> Void) {
    completion(loadEntry())
  }

  func getTimeline(in _: Context, completion: @escaping (Timeline<EasyCalendarWidgetEntry>) -> Void) {
    let entry = loadEntry()
    let refresh = Date().addingTimeInterval(15 * 60)
    completion(Timeline(entries: [entry], policy: .after(refresh)))
  }

  private func loadEntry() -> EasyCalendarWidgetEntry {
    switch WidgetSnapshotStore.load() {
    case .snapshot(let snapshot):
      return EasyCalendarWidgetEntry(date: Date(), snapshot: snapshot, hasError: false)
    case .missing:
      return EasyCalendarWidgetEntry(date: Date(), snapshot: EasyCalendarWidgetSnapshot(), hasError: false)
    case .invalid:
      return .error
    }
  }
}

struct EasyCalendarWidgetView: View {
  let entry: EasyCalendarWidgetEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("EasyCalendar")
          .font(.headline)
        Spacer()
        if !entry.hasError {
          Text(entry.snapshot.generatedAt, style: .time)
            .font(.caption2)
            .foregroundColor(.secondary)
        }
      }

      if entry.hasError {
        Text("暂时无法读取日程")
          .font(.subheadline)
          .foregroundColor(.secondary)
        Text("打开主 App 后会自动恢复")
          .font(.caption)
          .foregroundColor(.secondary)
      } else if entry.snapshot.todayEvents.isEmpty && entry.snapshot.dueItems.isEmpty {
        Text("今天没有安排")
          .font(.subheadline)
          .foregroundColor(.secondary)
        if let upcoming = entry.snapshot.upcomingEvents.first {
          WidgetItemLink(item: upcoming)
        }
      } else {
        ForEach(entry.snapshot.todayEvents.prefix(3)) { item in
          WidgetItemLink(item: item)
        }
        ForEach(entry.snapshot.dueItems.prefix(2)) { item in
          WidgetItemLink(item: item)
        }
      }
      Spacer(minLength: 0)
    }
    .padding()
    .widgetURL(URL(string: "easycalendar://today"))
  }
}

private struct WidgetItemLink: View {
  let item: EasyCalendarWidgetItem

  var body: some View {
    Link(destination: URL(string: "easycalendar://item/\(item.id)")!) {
      HStack(spacing: 6) {
        Circle()
          .fill(
            item.type == "task"
              ? Color.orange
              : Color(red: 0.06, green: 0.46, blue: 0.43)
          )
          .frame(width: 6, height: 6)
        VStack(alignment: .leading, spacing: 2) {
          Text(item.title)
            .font(.subheadline)
            .lineLimit(1)
          if let date = item.scheduleDate {
            Text(date, style: .time)
              .font(.caption)
              .foregroundColor(.secondary)
          }
        }
        Spacer(minLength: 0)
      }
    }
    .buttonStyle(.plain)
  }
}

@main
struct EasyCalendarWidgetBundle: WidgetBundle {
  var body: some Widget {
    EasyCalendarWidget()
  }
}

struct EasyCalendarWidget: Widget {
  let kind = "EasyCalendarWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: EasyCalendarWidgetProvider()) { entry in
      EasyCalendarWidgetView(entry: entry)
    }
    .configurationDisplayName("EasyCalendar")
    .description("查看今天和近期的日程与 Due")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}
