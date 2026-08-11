import Cocoa
import FlutterMacOS
import WidgetKit

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    WidgetSnapshotBridge.configure(with: flutterViewController)
    DesktopWindowBridge.configure(with: self, controller: flutterViewController)

    super.awakeFromNib()
  }
}

enum DesktopWindowBridge {
  private static let channelName = "io.easycalendar/window"
  private static weak var window: NSWindow?
  private static var channel: FlutterMethodChannel?
  private(set) static var interactionLocked = false

  static func configure(with window: NSWindow, controller: FlutterViewController) {
    self.window = window
    let methodChannel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: controller.engine.binaryMessenger
    )
    methodChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "setOpacity":
        guard let arguments = call.arguments as? [String: Any],
              let value = arguments["opacity"] as? Double else {
          result(FlutterError(code: "invalid_opacity", message: nil, details: nil))
          return
        }
        window.alphaValue = CGFloat(min(max(value, 0.2), 1.0))
        result(nil)
      case "setAlwaysOnTop":
        guard let arguments = call.arguments as? [String: Any],
              let value = arguments["value"] as? Bool else {
          result(FlutterError(code: "invalid_topmost", message: nil, details: nil))
          return
        }
        window.level = value ? .floating : .normal
        result(nil)
      case "setInteractionLocked":
        guard let arguments = call.arguments as? [String: Any],
              let value = arguments["value"] as? Bool else {
          result(FlutterError(code: "invalid_click_through", message: nil, details: nil))
          return
        }
        setInteractionLocked(value, notifyFlutter: false)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    channel = methodChannel
  }

  static func setInteractionLocked(_ value: Bool, notifyFlutter: Bool) {
    interactionLocked = value
    window?.ignoresMouseEvents = value
    if notifyFlutter {
      channel?.invokeMethod("windowInteractionUnlocked", arguments: nil)
    }
  }

  static func unlock() {
    setInteractionLocked(false, notifyFlutter: true)
  }
}

enum WidgetSnapshotBridge {
  private static let channelName = "io.easycalendar/widget"
  private static let appGroup = "group.io.easycalendar.easyCalendar"
  private static let relativePath = "widget/snapshot.json"
  private static var channel: FlutterMethodChannel?
  private static var dartReady = false
  private static var pendingURLs: [URL] = []

  static func configure(with controller: FlutterViewController) {
    let methodChannel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: controller.engine.binaryMessenger
    )
    methodChannel.setMethodCallHandler { call, result in
      if call.method == "readyForWidgetLinks" {
        dartReady = true
        pendingURLs.forEach(send)
        pendingURLs.removeAll()
        result(nil)
        return
      }
      guard call.method == "writeSnapshot",
            let arguments = call.arguments as? [String: Any],
            let json = arguments["json"] as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      do {
        try write(json: json)
        result(nil)
      } catch {
        result(FlutterError(
          code: "widget_snapshot_write_failed",
          message: error.localizedDescription,
          details: nil
        ))
      }
    }
    channel = methodChannel
  }

  static func open(url: URL) {
    guard dartReady else {
      pendingURLs.append(url)
      return
    }
    send(url: url)
  }

  private static func send(url: URL) {
    channel?.invokeMethod("openWidgetTarget", arguments: url.absoluteString)
  }

  private static func write(json: String) throws {
    guard let container = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroup
    ) else {
      throw NSError(domain: "EasyCalendarWidget", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "App Group container is unavailable"
      ])
    }
    let directory = container.appendingPathComponent("widget", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = container.appendingPathComponent(relativePath)
    let temporary = directory.appendingPathComponent(".snapshot-\(UUID().uuidString).tmp")
    try Data(json.utf8).write(to: temporary, options: .atomic)
    if FileManager.default.fileExists(atPath: destination.path) {
      _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
    } else {
      try FileManager.default.moveItem(at: temporary, to: destination)
    }
    if #available(macOS 11.0, *) {
      WidgetCenter.shared.reloadAllTimelines()
    }
  }
}
