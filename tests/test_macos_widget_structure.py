"""Static checks for the macOS WidgetKit target and App Group bridge."""

from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
CLIENT = ROOT / "client"
MACOS = CLIENT / "macos"


def test_widgetkit_target_and_shared_snapshot_contract_are_present():
    source = (MACOS / "EasyCalendarWidget" / "EasyCalendarWidget.swift").read_text(
        encoding="utf-8"
    )
    project = (MACOS / "Runner.xcodeproj" / "project.pbxproj").read_text(
        encoding="utf-8"
    )
    bridge = (MACOS / "Runner" / "MainFlutterWindow.swift").read_text(
        encoding="utf-8"
    )

    assert "import WidgetKit" in source
    assert "TimelineProvider" in source
    assert "Timeline(entries:" in source
    assert "widgetURL(URL(string: \"easycalendar://today\"))" in source
    assert "case .invalid" in source
    assert "com.apple.widgetkit-extension" in (
        MACOS / "EasyCalendarWidget" / "Info.plist"
    ).read_text(encoding="utf-8")
    assert "com.apple.product-type.app-extension" in project
    assert "EasyCalendarWidget.appex" in project
    assert "MACOSX_DEPLOYMENT_TARGET = 11.0" in project
    assert "group.io.easycalendar.easyCalendar" in bridge
    assert "reloadAllTimelines" in bridge
    assert "readyForWidgetLinks" in bridge
    assert "pendingURLs" in bridge


def test_runner_and_widget_share_app_group_and_flutter_publishes_snapshot():
    app_group = "group.io.easycalendar.easyCalendar"
    for relative in (
        "macos/Runner/DebugProfile.entitlements",
        "macos/Runner/Release.entitlements",
        "macos/EasyCalendarWidget/EasyCalendarWidget.entitlements",
    ):
        assert app_group in (CLIENT / relative).read_text(encoding="utf-8")

    writer = (CLIENT / "lib" / "widget" / "widget_snapshot_writer.dart").read_text(
        encoding="utf-8"
    )
    controller = (CLIENT / "lib" / "application" / "item_controller.dart").read_text(
        encoding="utf-8"
    )
    deep_links = (
        CLIENT / "lib" / "widget" / "widget_deep_link_controller.dart"
    ).read_text(encoding="utf-8")
    assert "writeSnapshot" in writer
    assert "today_events" in writer
    assert "due_items" in writer
    assert "widgetSnapshotWriter" in controller
    assert "openWidgetTarget" in deep_links
    assert "readyForWidgetLinks" in deep_links
