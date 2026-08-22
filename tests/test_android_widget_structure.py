"""Static contracts for the two standard Android home-screen widgets."""

from pathlib import Path
from xml.etree import ElementTree


ROOT = Path(__file__).resolve().parent.parent
ANDROID = ROOT / "client" / "android" / "app" / "src" / "main"
ANDROID_NS = "{http://schemas.android.com/apk/res/android}"


def test_manifest_registers_two_standard_app_widget_providers_and_deep_links():
    manifest = ElementTree.parse(ANDROID / "AndroidManifest.xml").getroot()
    application = manifest.find("application")
    assert application is not None

    receiver_names = {
        receiver.attrib[f"{ANDROID_NS}name"]
        for receiver in application.findall("receiver")
    }
    assert ".widget.DueWidgetProvider" in receiver_names
    assert ".widget.WeekWidgetProvider" in receiver_names

    source = (ANDROID / "AndroidManifest.xml").read_text(encoding="utf-8")
    assert "android.appwidget.action.APPWIDGET_UPDATE" in source
    assert 'android:scheme="easycalendar"' in source
    assert "com.oplus" not in source
    assert "com.coloros" not in source


def test_widget_metadata_declares_requested_fixed_grid_sizes():
    due = ElementTree.parse(ANDROID / "res" / "xml" / "widget_due_info.xml").getroot()
    week = ElementTree.parse(ANDROID / "res" / "xml" / "widget_week_info.xml").getroot()

    assert due.attrib[f"{ANDROID_NS}targetCellWidth"] == "4"
    assert due.attrib[f"{ANDROID_NS}targetCellHeight"] == "2"
    assert due.attrib[f"{ANDROID_NS}resizeMode"] == "none"
    assert due.attrib[f"{ANDROID_NS}updatePeriodMillis"] == "1800000"
    assert week.attrib[f"{ANDROID_NS}targetCellWidth"] == "4"
    assert week.attrib[f"{ANDROID_NS}targetCellHeight"] == "4"
    assert week.attrib[f"{ANDROID_NS}resizeMode"] == "none"
    assert week.attrib[f"{ANDROID_NS}updatePeriodMillis"] == "1800000"


def test_widgets_consume_the_shared_snapshot_without_opening_sqlite():
    kotlin_dir = ANDROID / "kotlin" / "io" / "easycalendar" / "easy_calendar"
    snapshot = (kotlin_dir / "widget" / "WidgetSnapshot.kt").read_text(
        encoding="utf-8"
    )
    renderer = (kotlin_dir / "widget" / "EasyCalendarWidgetRenderer.kt").read_text(
        encoding="utf-8"
    )
    activity = (kotlin_dir / "MainActivity.kt").read_text(encoding="utf-8")
    dart_writer = (
        ROOT / "client" / "lib" / "widget" / "widget_snapshot_writer.dart"
    ).read_text(encoding="utf-8")

    combined = snapshot + renderer
    assert "week_events" in snapshot
    assert "calendar_events" in snapshot
    assert "due_items" in snapshot
    assert "SQLite" not in combined
    assert "sqflite" not in combined
    assert "easycalendar://due" not in renderer
    assert "easycalendar://today" in renderer
    assert "writeSnapshot" in activity
    assert "Platform.isAndroid" in dart_writer
    assert "week_events" in dart_writer
    assert "calendar_events" in dart_writer
    assert "WidgetSnapshotSchema.version" in dart_writer
    assert "SCHEMA_VERSION" in snapshot
    assert "MAX_BITMAP_PIXELS" in renderer
    assert "OPTION_APPWIDGET_MAX_WIDTH" not in (
        kotlin_dir / "widget" / "WeekWidgetProvider.kt"
    ).read_text(encoding="utf-8")


def test_widget_layouts_have_stable_slots_and_dark_colors():
    due = (ANDROID / "res" / "layout" / "widget_due.xml").read_text(
        encoding="utf-8"
    )
    week = (ANDROID / "res" / "layout" / "widget_week.xml").read_text(
        encoding="utf-8"
    )

    assert all(f"due_row_{index}" in due for index in range(1, 4))
    assert "widget_week_root" in week
    assert "week_snapshot" in week
    assert "week_row_1" not in week
    assert (ANDROID / "res" / "values-night" / "colors.xml").is_file()


def test_due_widget_completes_items_without_an_app_open_pending_intent():
    renderer = (
        ANDROID
        / "kotlin"
        / "io"
        / "easycalendar"
        / "easy_calendar"
        / "widget"
        / "EasyCalendarWidgetRenderer.kt"
    ).read_text(encoding="utf-8")
    actions = (
        ANDROID
        / "kotlin"
        / "io"
        / "easycalendar"
        / "easy_calendar"
        / "widget"
        / "DueWidgetActions.kt"
    ).read_text(encoding="utf-8")

    assert "ACTION_COMPLETE_DUE" in renderer
    assert "completeDueIntent" in renderer
    assert "openAppIntent" not in actions
