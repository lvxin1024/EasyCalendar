"""iCal client implementation for device calendars."""

import os
from typing import List, Optional
from datetime import datetime
from pathlib import Path
import vobject

from .base_client import BaseCalendarClient
from ..parser.models import CalendarEvent, RecurrenceType
from ...config.settings import ICAL_CONFIG


class ICalClient(BaseCalendarClient):
    """Client for iCal/ICS format calendar files."""

    def __init__(self, output_dir: Optional[str] = None):
        self.output_dir = Path(output_dir or ICAL_CONFIG["output_dir"])
        self.output_dir.mkdir(parents=True, exist_ok=True)
        self._events_cache: List[CalendarEvent] = []

    def create_event(self, event: CalendarEvent) -> Optional[str]:
        """Create a calendar event in iCal format."""
        try:
            event_id = f"event_{datetime.now().timestamp()}"
            self._events_cache.append(event)
            return event_id
        except Exception as error:
            print(f"Error creating event: {error}")
            return None

    def get_event(self, event_id: str) -> Optional[CalendarEvent]:
        """Get a calendar event by ID."""
        for event in self._events_cache:
            if event.source_text == event_id:
                return event
        return None

    def update_event(self, event_id: str, event: CalendarEvent) -> bool:
        """Update an existing calendar event."""
        for i, cached_event in enumerate(self._events_cache):
            if cached_event.source_text == event_id:
                self._events_cache[i] = event
                return True
        return False

    def delete_event(self, event_id: str) -> bool:
        """Delete a calendar event."""
        for i, event in enumerate(self._events_cache):
            if event.source_text == event_id:
                del self._events_cache[i]
                return True
        return False

    def list_events(
        self,
        start_date: Optional[datetime] = None,
        end_date: Optional[datetime] = None,
        max_results: int = 100,
    ) -> List[CalendarEvent]:
        """List calendar events within a date range."""
        events = self._events_cache

        if start_date:
            events = [e for e in events if e.start_time >= start_date]
        if end_date:
            events = [e for e in events if e.end_time <= end_date]

        return events[:max_results]

    def export_calendar(self, filename: str = "calendar.ics") -> str:
        """Export calendar to iCal format file."""
        filepath = self.output_dir / filename
        ical_string = self._generate_ical_string(self._events_cache)

        with open(filepath, "w", encoding="utf-8") as f:
            f.write(ical_string)

        return str(filepath)

    def import_calendar(self, filepath: str) -> List[CalendarEvent]:
        """Import calendar from iCal format file."""
        events = []

        with open(filepath, "r", encoding="utf-8") as f:
            calendar = vobject.readOne(f.read())

        for vevent in calendar.vevent_list:
            event = self._vevent_to_event(vevent)
            if event:
                events.append(event)

        self._events_cache.extend(events)
        return events

    def _generate_ical_string(self, events: List[CalendarEvent]) -> str:
        """Generate iCal format string from events."""
        calendar = vobject.iCalendar()

        for event in events:
            vevent = calendar.add("vevent")
            vevent.add("uid").value = f"{event.title}@{datetime.now().timestamp()}"
            vevent.add("summary").value = event.title

            dtstart = vevent.add("dtstart")
            dtstart.value = event.start_time
            dtstart.params["VALUE"] = "DATE-TIME"

            dtend = vevent.add("dtend")
            dtend.value = event.end_time
            dtend.params["VALUE"] = "DATE-TIME"

            if event.location:
                vevent.add("location").value = event.location

            if event.description:
                vevent.add("description").value = event.description

            for attendee in event.attendees:
                vevent.add("attendee").value = f"mailto:{attendee}"

            if event.recurrence != RecurrenceType.NONE:
                rrule_map = {
                    RecurrenceType.DAILY: "FREQ=DAILY",
                    RecurrenceType.WEEKLY: "FREQ=WEEKLY",
                    RecurrenceType.MONTHLY: "FREQ=MONTHLY",
                    RecurrenceType.YEARLY: "FREQ=YEARLY",
                }
                vevent.add("rrule").value = vobject.ircal.RecurrenceRule(
                    freq=rrule_map[event.recurrence]
                )

        return calendar.serialize()

    def _vevent_to_event(self, vevent) -> Optional[CalendarEvent]:
        """Convert vobject VEVENT to CalendarEvent."""
        try:
            start_time = getattr(vevent, "dtstart", None)
            end_time = getattr(vevent, "dtend", None)

            if start_time:
                start_time = start_time.value
            if end_time:
                end_time = end_time.value

            if not isinstance(start_time, datetime):
                start_time = datetime.combine(start_time, datetime.min.time())
            if not isinstance(end_time, datetime):
                end_time = datetime.combine(end_time, datetime.min.time())

            title = str(getattr(vevent, "summary", None).value if hasattr(vevent, "summary") else "Untitled")
            location = str(getattr(vevent, "location", None).value) if hasattr(vevent, "location") else None
            description = str(getattr(vevent, "description", None).value) if hasattr(vevent, "description") else None

            attendees = []
            if hasattr(vevent, "attendee_list"):
                attendees = [str(a.value).replace("mailto:", "") for a in vevent.attendee_list]

            uid = str(getattr(vevent, "uid", None).value) if hasattr(vevent, "uid") else ""

            return CalendarEvent(
                title=title,
                start_time=start_time,
                end_time=end_time,
                description=description,
                location=location,
                attendees=attendees,
                source_text=uid,
            )
        except Exception as error:
            print(f"Error parsing VEVENT: {error}")
            return None
