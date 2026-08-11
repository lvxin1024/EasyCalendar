"""Legacy calendar models and parser result compatibility helpers."""

from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional, List
from enum import Enum

from ..domain.models import CandidateItem, SourceTextSpan


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
    """Represents parser output, with candidates as the primary result.

    ``events`` remains available as a compatibility view for the original
    calendar-client prototype. New code should consume ``candidates``.
    """

    original_text: str
    candidates: List[CandidateItem]
    raw_entities: dict = field(default_factory=dict)
    confidence: float = 1.0

    @property
    def events(self) -> List[CalendarEvent]:
        """Return the old event-shaped view without confirming candidates."""
        return [self._candidate_to_event(candidate) for candidate in self.candidates]

    @staticmethod
    def _candidate_to_event(candidate: CandidateItem) -> CalendarEvent:
        """Adapt a candidate for legacy calendar-client callers."""
        start_time = candidate.start_at or candidate.due_at
        if start_time is None:
            start_time = datetime.now().replace(hour=9, minute=0, second=0, microsecond=0)
        end_time = candidate.end_at or start_time

        return CalendarEvent(
            title=candidate.title,
            start_time=start_time,
            end_time=end_time,
            description=candidate.body,
            location=candidate.location,
            attendees=list(candidate.attendees),
            priority=EventPriority(candidate.priority or EventPriority.NORMAL.value),
            recurrence=RecurrenceType(
                candidate.recurrence.rrule.removeprefix("FREQ=").lower()
            )
            if candidate.recurrence
            and candidate.recurrence.rrule.removeprefix("FREQ=").lower()
            in {recurrence.value for recurrence in RecurrenceType}
            else RecurrenceType.NONE,
            timezone=candidate.timezone or "Asia/Shanghai",
        )

    def __len__(self):
        return len(self.candidates)

    def __iter__(self):
        return iter(self.events)
