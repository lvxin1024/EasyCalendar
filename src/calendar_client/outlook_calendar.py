"""Outlook Calendar client implementation."""

import os
from typing import List, Optional
from datetime import datetime, timedelta
import msal
import requests

from .base_client import BaseCalendarClient
from ..parser.models import CalendarEvent, RecurrenceType
from ...config.settings import OUTLOOK_CONFIG


class OutlookCalendarClient(BaseCalendarClient):
    """Client for Microsoft Outlook Calendar API (Microsoft Graph)."""

    GRAPH_URL = "https://graph.microsoft.com/v1.0"

    def __init__(
        self,
        client_id: Optional[str] = None,
        client_secret: Optional[str] = None,
        tenant_id: Optional[str] = None,
    ):
        self.client_id = client_id or OUTLOOK_CONFIG["client_id"]
        self.client_secret = client_secret or OUTLOOK_CONFIG["client_secret"]
        self.tenant_id = tenant_id or OUTLOOK_CONFIG["tenant_id"]
        self.access_token = None
        self._authenticate()

    def _authenticate(self):
        """Authenticate with Microsoft Graph API."""
        authority = f"https://login.microsoftonline.com/{self.tenant_id}"
        app = msal.ConfidentialClientApplication(
            self.client_id,
            authority=authority,
            client_credential=self.client_secret,
        )

        result = app.acquire_token_for_client(
            scopes=["https://graph.microsoft.com/.default"]
        )

        if "access_token" in result:
            self.access_token = result["access_token"]
        else:
            raise Exception(f"Authentication failed: {result.get('error_description')}")

    def _get_headers(self) -> dict:
        """Get authorization headers."""
        return {
            "Authorization": f"Bearer {self.access_token}",
            "Content-Type": "application/json",
        }

    def create_event(self, event: CalendarEvent) -> Optional[str]:
        """Create a calendar event in Outlook Calendar."""
        try:
            event_dict = self._event_to_outlook_format(event)
            response = requests.post(
                f"{self.GRAPH_URL}/me/events",
                headers=self._get_headers(),
                json=event_dict,
            )
            if response.status_code == 201:
                return response.json().get("id")
            return None
        except Exception as error:
            print(f"Error creating event: {error}")
            return None

    def get_event(self, event_id: str) -> Optional[CalendarEvent]:
        """Get a calendar event by ID."""
        try:
            response = requests.get(
                f"{self.GRAPH_URL}/me/events/{event_id}",
                headers=self._get_headers(),
            )
            if response.status_code == 200:
                return self._outlook_to_event(response.json())
            return None
        except Exception:
            return None

    def update_event(self, event_id: str, event: CalendarEvent) -> bool:
        """Update an existing calendar event."""
        try:
            event_dict = self._event_to_outlook_format(event)
            response = requests.patch(
                f"{self.GRAPH_URL}/me/events/{event_id}",
                headers=self._get_headers(),
                json=event_dict,
            )
            return response.status_code == 200
        except Exception:
            return False

    def delete_event(self, event_id: str) -> bool:
        """Delete a calendar event."""
        try:
            response = requests.delete(
                f"{self.GRAPH_URL}/me/events/{event_id}",
                headers=self._get_headers(),
            )
            return response.status_code == 204
        except Exception:
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

            params = {
                "$filter": f"start/dateTime ge '{start_date.isoformat()}Z' and end/dateTime le '{end_date.isoformat()}Z'",
                "$top": str(max_results),
                "$orderby": "start/dateTime",
            }

            response = requests.get(
                f"{self.GRAPH_URL}/me/calendar/events",
                headers=self._get_headers(),
                params=params,
            )

            if response.status_code == 200:
                events = response.json().get("value", [])
                return [self._outlook_to_event(e) for e in events]
            return []
        except Exception:
            return []

    def export_calendar(self) -> str:
        """Export calendar to iCal format."""
        events = self.list_events(max_results=1000)
        return self._generate_ical(events)

    def _event_to_outlook_format(self, event: CalendarEvent) -> dict:
        """Convert CalendarEvent to Microsoft Graph API format."""
        event_dict = {
            "subject": event.title,
            "body": {
                "contentType": "text",
                "content": event.description or "",
            },
            "start": {
                "dateTime": event.start_time.isoformat(),
                "timeZone": event.timezone,
            },
            "end": {
                "dateTime": event.end_time.isoformat(),
                "timeZone": event.timezone,
            },
            "location": {"displayName": event.location or ""},
            "attendees": [
                {"emailAddress": {"address": email}, "type": "required"}
                for email in event.attendees
            ],
        }

        if event.recurrence != RecurrenceType.NONE:
            recurrence_patterns = {
                RecurrenceType.DAILY: {
                    "pattern": {"type": "daily", "interval": 1},
                    "range": {"type": "noEnd"},
                },
                RecurrenceType.WEEKLY: {
                    "pattern": {"type": "weekly", "interval": 1},
                    "range": {"type": "noEnd"},
                },
                RecurrenceType.MONTHLY: {
                    "pattern": {"type": "absoluteMonthly", "interval": 1},
                    "range": {"type": "noEnd"},
                },
                RecurrenceType.YEARLY: {
                    "pattern": {"type": "absoluteYearly", "interval": 1},
                    "range": {"type": "noEnd"},
                },
            }
            event_dict["recurrence"] = recurrence_patterns[event.recurrence]

        return event_dict

    def _outlook_to_event(self, outlook_event: dict) -> CalendarEvent:
        """Convert Microsoft Graph event to CalendarEvent."""
        start = outlook_event.get("start", {})
        end = outlook_event.get("end", {})
        body = outlook_event.get("body", {})
        location = outlook_event.get("location", {})

        start_time = datetime.fromisoformat(start.get("dateTime", "").replace("Z", "+00:00"))
        end_time = datetime.fromisoformat(end.get("dateTime", "").replace("Z", "+00:00"))

        attendees = []
        for attendee in outlook_event.get("attendees", []):
            email = attendee.get("emailAddress", {}).get("address")
            if email:
                attendees.append(email)

        return CalendarEvent(
            title=outlook_event.get("subject", ""),
            start_time=start_time,
            end_time=end_time,
            description=body.get("content"),
            location=location.get("displayName"),
            attendees=attendees,
            source_text=str(outlook_event.get("id", "")),
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
