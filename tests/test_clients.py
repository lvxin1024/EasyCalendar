"""Unit tests for calendar clients."""

import pytest
from datetime import datetime, timedelta
from src.calendar_client.ical_client import ICalClient
from src.parser.models import CalendarEvent


class TestICalClient:
    """Test cases for ICalClient."""

    def setup_method(self):
        """Setup test fixtures."""
        self.client = ICalClient(output_dir="/tmp/test_calendars")

    def test_create_event(self):
        """Test creating an event."""
        event = CalendarEvent(
            title="测试会议",
            start_time=datetime(2024, 3, 20, 9, 0),
            end_time=datetime(2024, 3, 20, 10, 0),
            description="测试描述",
            location="会议室A"
        )

        event_id = self.client.create_event(event)
        assert event_id is not None

    def test_list_events(self):
        """Test listing events."""
        events = self.client.list_events()
        assert isinstance(events, list)

    def test_export_calendar(self):
        """Test exporting calendar."""
        event = CalendarEvent(
            title="导出会议",
            start_time=datetime(2024, 3, 20, 14, 0),
            end_time=datetime(2024, 3, 20, 15, 0)
        )
        self.client.create_event(event)

        filepath = self.client.export_calendar("test_export.ics")
        assert filepath is not None
        assert "test_export.ics" in filepath

    def test_update_event(self):
        """Test updating an event."""
        event = CalendarEvent(
            title="原标题",
            start_time=datetime(2024, 3, 20, 9, 0),
            end_time=datetime(2024, 3, 20, 10, 0)
        )

        event_id = self.client.create_event(event)
        assert event_id is not None

        updated_event = CalendarEvent(
            title="更新后标题",
            start_time=datetime(2024, 3, 20, 9, 0),
            end_time=datetime(2024, 3, 20, 10, 0)
        )

        result = self.client.update_event(event_id, updated_event)
        assert result is True

    def test_delete_event(self):
        """Test deleting an event."""
        event = CalendarEvent(
            title="待删除会议",
            start_time=datetime(2024, 3, 20, 9, 0),
            end_time=datetime(2024, 3, 20, 10, 0)
        )

        event_id = self.client.create_event(event)
        result = self.client.delete_event(event_id)
        assert result is True


class TestCalendarEventModel:
    """Test cases for CalendarEvent model."""

    def test_event_with_attendees(self):
        """Test event with attendees."""
        event = CalendarEvent(
            title="团队会议",
            start_time=datetime(2024, 3, 20, 9, 0),
            end_time=datetime(2024, 3, 20, 10, 0),
            attendees=["user1@example.com", "user2@example.com"]
        )

        assert len(event.attendees) == 2
        assert "user1@example.com" in event.attendees

    def test_event_with_recurrence(self):
        """Test event with recurrence."""
        from src.parser.models import RecurrenceType

        event = CalendarEvent(
            title="每周例会",
            start_time=datetime(2024, 3, 20, 9, 0),
            end_time=datetime(2024, 3, 20, 10, 0),
            recurrence=RecurrenceType.WEEKLY
        )

        assert event.recurrence == RecurrenceType.WEEKLY


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
