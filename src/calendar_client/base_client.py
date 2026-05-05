"""Base calendar client interface."""

from abc import ABC, abstractmethod
from typing import List, Optional, Dict, Any
from ..parser.models import CalendarEvent


class BaseCalendarClient(ABC):
    """Abstract base class for calendar clients."""

    @abstractmethod
    def create_event(self, event: CalendarEvent) -> Optional[str]:
        """Create a calendar event.

        Args:
            event: CalendarEvent to create

        Returns:
            Event ID if successful, None otherwise
        """
        pass

    @abstractmethod
    def get_event(self, event_id: str) -> Optional[CalendarEvent]:
        """Get a calendar event by ID.

        Args:
            event_id: Event ID

        Returns:
            CalendarEvent if found, None otherwise
        """
        pass

    @abstractmethod
    def update_event(self, event_id: str, event: CalendarEvent) -> bool:
        """Update an existing calendar event.

        Args:
            event_id: Event ID to update
            event: Updated CalendarEvent

        Returns:
            True if successful, False otherwise
        """
        pass

    @abstractmethod
    def delete_event(self, event_id: str) -> bool:
        """Delete a calendar event.

        Args:
            event_id: Event ID to delete

        Returns:
            True if successful, False otherwise
        """
        pass

    @abstractmethod
    def list_events(
        self,
        start_date: Optional[Any] = None,
        end_date: Optional[Any] = None,
        max_results: int = 100,
    ) -> List[CalendarEvent]:
        """List calendar events within a date range.

        Args:
            start_date: Start date/time
            end_date: End date/time
            max_results: Maximum number of events to return

        Returns:
            List of CalendarEvent objects
        """
        pass

    @abstractmethod
    def export_calendar(self) -> str:
        """Export calendar to iCal format.

        Returns:
            iCal format string
        """
        pass
