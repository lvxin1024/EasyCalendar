import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func application(_ application: NSApplication, open urls: [URL]) {
    urls.forEach(WidgetSnapshotBridge.open)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
    let menu = NSMenu()
    let item = NSMenuItem(
      title: "解除窗口交互锁定",
      action: #selector(unlockWindowInteraction(_:)),
      keyEquivalent: ""
    )
    item.target = self
    item.isEnabled = DesktopWindowBridge.interactionLocked
    menu.addItem(item)
    return menu
  }

  @objc private func unlockWindowInteraction(_ sender: Any?) {
    DesktopWindowBridge.unlock()
  }
}
