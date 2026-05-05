"""Data models for calendar events."""

from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional, List
from enum import Enum


class EventPriority(Enum):
    LOW = 1
    NORMAL = 2
    HIGH = 3


class EventStatus(Enum):
    CONFIRMED = "confirmed"
    TENTATIVE = "tentative"
    CANCELLED = "cancelled"


class RecurrenceType(Enum):
    NONE = "none"
    DAILY = "daily"
    WEEKLY = "weekly"
    MONTHLY = "monthly"
    YEARLY = "yearly"


@dataclass
class CalendarEvent:
    """Represents a calendar event."""

    title: str
    start_time: datetime
    end_time: datetime
    description: Optional[str] = None
    location: Optional[str] = None
    attendees: List[str] = field(default_factory=list)
    priority: EventPriority = EventPriority.NORMAL
    status: EventStatus = EventStatus.CONFIRMED
    recurrence: RecurrenceType = RecurrenceType.NONE
    recurrence_count: Optional[int] = None
    reminder_minutes: Optional[int] = None
    timezone: str = "Asia/Shanghai"
    source_text: str = ""

    def __post_init__(self):
        if self.end_time < self.start_time:
            self.end_time = self.start_time


@dataclass
class ParsedSchedule:
    """Represents a parsed schedule containing multiple events."""

    original_text: str
    events: List[CalendarEvent]
    raw_entities: dict = field(default_factory=dict)
    confidence: float = 1.0

    def __len__(self):
        return len(self.events)

    def __iter__(self):
        return iter(self.events)
