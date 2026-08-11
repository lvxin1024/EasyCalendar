"""Google Calendar client implementation."""

import os
from typing import List, Optional
from datetime import datetime
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError

from .base_client import BaseCalendarClient
from ..parser.models import CalendarEvent, EventPriority, RecurrenceType

try:
    from config.settings import GOOGLE_CALENDAR_CONFIG
except ImportError:
    GOOGLE_CALENDAR_CONFIG = {
        "credentials_file": "config/google_credentials.json",
        "token_file": "config/google_token.json",
    }


class GoogleCalendarClient(BaseCalendarClient):
    """Client for Google Calendar API."""

    SCOPES = ["https://www.googleapis.com/auth/calendar"]

    def __init__(
        self,
        credentials_file: Optional[str] = None,
        token_file: Optional[str] = None,
    ):
        self.credentials_file = credentials_file or GOOGLE_CALENDAR_CONFIG["credentials_file"]
        self.token_file = token_file or GOOGLE_CALENDAR_CONFIG["token_file"]
        self.service = None
        self._authenticate()

    def _authenticate(self):
        """Authenticate with Google Calendar API."""
        creds = None

        if os.path.exists(self.token_file):
            creds = Credentials.from_authorized_user_file(self.token_file, self.SCOPES)

        if not creds or not creds.valid:
            if creds and creds.expired and creds.refresh_token:
                creds.refresh(
                    google.auth.transport.requests.Request()
                )
            else:
                flow = InstalledAppFlow.from_client_secrets_file(
                    self.credentials_file, self.SCOPES
                )
                creds = flow.run_local_server(port=0)

            with open(self.token_file, "w") as token:
                token.write(creds.to_json())

        self.service = build("calendar", "v3", credentials=creds)

    def create_event(self, event: CalendarEvent) -> Optional[str]:
        """Create a calendar event in Google Calendar."""
        try:
            event_dict = self._event_to_google_format(event)
            created_event = (
                self.service.events().insert(
                    calendarId="primary", body=event_dict
                ).execute()
            )
            return created_event.get("id")
        except HttpError as error:
            print(f"Error creating event: {error}")
            return None
        except Exception as error:
            print(f"Unexpected error: {error}")
            return None

    def get_event(self, event_id: str) -> Optional[CalendarEvent]:
        """Get a calendar event by ID."""
        try:
            event = (
                self.service.events()
                .get(calendarId="primary", eventId=event_id)
                .execute()
            )
            return self._google_to_event(event)
        except HttpError:
            return None

    def update_event(self, event_id: str, event: CalendarEvent) -> bool:
        """Update an existing calendar event."""
        try:
            event_dict = self._event_to_google_format(event)
            self.service.events().update(
                calendarId="primary", eventId=event_id, body=event_dict
            ).execute()
            return True
        except HttpError:
            return False

    def delete_event(self, event_id: str) -> bool:
        """Delete a calendar event."""
        try:
            self.service.events().delete(
                calendarId="primary", eventId=event_id
            ).execute()
            return True
        except HttpError:
            return False

    def list_events(
        self,
        start_date: Optional[datetime] = None,
        end_date: Optional[datetime] = None,
        max_results: int = 100,
    ) -> List[CalendarEvent]:
        """List calendar events within a date range."""
        try:
            if not start_date:
                start_date = datetime.utcnow()
            if not end_date:
                end_date = start_date + timedelta(days=30)

            events_result = (
                self.service.events()
                .list(
                    calendarId="primary",
                    timeMin=start_date.isoformat() + "Z",
                    timeMax=end_date.isoformat() + "Z",
                    maxResults=max_results,
                    singleEvents=True,
                    orderBy="startTime",
                )
                .execute()
            )

            events = events_result.get("items", [])
            return [self._google_to_event(e) for e in events if e.get("start")]

        except HttpError:
            return []

    def export_calendar(self) -> str:
        """Export calendar to iCal format."""
        events = self.list_events(max_results=1000)
        return self._generate_ical(events)

    def _event_to_google_format(self, event: CalendarEvent) -> dict:
        """Convert CalendarEvent to Google Calendar API format."""
        event_dict = {
            "summary": event.title,
            "location": event.location,
            "description": event.description,
            "start": {
                "dateTime": event.start_time.isoformat(),
                "timeZone": event.timezone,
            },
            "end": {
                "dateTime": event.end_time.isoformat(),
                "timeZone": event.timezone,
            },
            "recurrence": [],
            "attendees": [{"email": email} for email in event.attendees],
            "reminders": {
                "useDefault": False,
                "overrides": [
                    {"method": "popup", "minutes": event.reminder_minutes or 30}
                ],
            },
        }

        if event.recurrence != RecurrenceType.NONE:
            recurrence_rules = {
                RecurrenceType.DAILY: "RRULE:FREQ=DAILY",
                RecurrenceType.WEEKLY: "RRULE:FREQ=WEEKLY",
                RecurrenceType.MONTHLY: "RRULE:FREQ=MONTHLY",
                RecurrenceType.YEARLY: "RRULE:FREQ=YEARLY",
            }
            event_dict["recurrence"] = [recurrence_rules[event.recurrence]]

        return event_dict

    def _google_to_event(self, google_event: dict) -> CalendarEvent:
        """Convert Google Calendar event to CalendarEvent."""
        start = google_event.get("start", {})
        end = google_event.get("end", {})

        start_time = start.get("dateTime", start.get("date"))
        end_time = end.get("dateTime", end.get("date"))

        if isinstance(start_time, str):
            start_time = datetime.fromisoformat(start_time.replace("Z", "+00:00"))
        if isinstance(end_time, str):
            end_time = datetime.fromisoformat(end_time.replace("Z", "+00:00"))

        attendees = []
        for attendee in google_event.get("attendees", []):
            if "email" in attendee:
                attendees.append(attendee["email"])

        return CalendarEvent(
            title=google_event.get("summary", ""),
            start_time=start_time,
            end_time=end_time,
            description=google_event.get("description"),
            location=google_event.get("location"),
            attendees=attendees,
            source_text=str(google_event.get("id", "")),
        )

    def _generate_ical(self, events: List[CalendarEvent]) -> str:
        """Generate iCal format string from events."""
        from icalendar import Calendar, Event as ICalEvent

        cal = Calendar()
        for event in events:
            ical_event = ICalEvent()
            ical_event.add("summary", event.title)
            ical_event.add("dtstart", event.start_time)
            ical_event.add("dtend", event.end_time)
            if event.location:
                ical_event.add("location", event.location)
            if event.description:
                ical_event.add("description", event.description)
            cal.add_component(ical_event)

        return cal.to_ical().decode("utf-8")


from datetime import timedelta
