"""Offline tests for optional calendar provider implementations."""

from datetime import datetime
from importlib import import_module
from pathlib import Path

import pytest


pytestmark = pytest.mark.provider
vobject = pytest.importorskip("vobject", reason="calendar providers are optional")

from src.calendar_client.ical_client import ICalClient
from src.parser.models import CalendarEvent


@pytest.fixture
def client(tmp_path):
    return ICalClient(output_dir=str(tmp_path))


def make_event(title: str = "测试会议") -> CalendarEvent:
    return CalendarEvent(
        title=title,
        start_time=datetime(2024, 3, 20, 9, 0),
        end_time=datetime(2024, 3, 20, 10, 0),
        description="测试描述",
        location="会议室A",
    )


def test_create_and_get_event(client):
    event = make_event()

    event_id = client.create_event(event)

    assert event_id is not None
    assert client.get_event(event_id) == event


def test_list_events(client):
    client.create_event(make_event())

    events = client.list_events()

    assert len(events) == 1


def test_export_calendar_is_valid_ics(client, tmp_path):
    client.create_event(make_event("导出会议"))

    filepath = Path(client.export_calendar("test_export.ics"))
    calendar = vobject.readOne(filepath.read_text(encoding="utf-8"))

    assert filepath.parent == tmp_path
    assert calendar.vevent.summary.value == "导出会议"
    assert "VALUE=D,A,T,E" not in filepath.read_text(encoding="utf-8")


def test_update_event(client):
    event_id = client.create_event(make_event("原标题"))
    updated_event = make_event("更新后标题")

    assert client.update_event(event_id, updated_event) is True
    assert client.get_event(event_id).title == "更新后标题"


def test_delete_event(client):
    event_id = client.create_event(make_event("待删除会议"))

    assert client.delete_event(event_id) is True
    assert client.get_event(event_id) is None


@pytest.mark.parametrize(
    ("module_name", "class_name"),
    [
        ("src.calendar_client.google_calendar", "GoogleCalendarClient"),
        ("src.calendar_client.outlook_calendar", "OutlookCalendarClient"),
    ],
)
def test_remote_provider_modules_import_without_authentication(module_name, class_name):
    module = import_module(module_name)

    assert getattr(module, class_name) is not None
