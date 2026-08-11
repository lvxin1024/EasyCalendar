"""Core data models for the single-user schedule and due app."""

from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from typing import Any, Dict, List, Optional


class ItemType(str, Enum):
    """Kinds of records that can be stored as a formal item."""

    EVENT = "event"
    TASK = "task"
    NOTE = "note"


class ItemStatus(str, Enum):
    """Lifecycle state for an item."""

    TODO = "todo"
    DONE = "done"
    CANCELLED = "cancelled"


class ItemSource(str, Enum):
    """Origin of a formal item."""

    LOCAL = "local"
    ICS = "ics"
    AI = "ai"
    GOOGLE = "google"
    MICROSOFT = "microsoft"
    LARK = "lark"
    PLUGIN = "plugin"


class ReminderMode(str, Enum):
    """Ways a reminder can be scheduled."""

    RELATIVE = "relative"
    ABSOLUTE = "absolute"


@dataclass
class SourceTextSpan:
    """Character offsets for the text that produced a candidate."""

    start: int
    end: int


@dataclass
class RecurrenceRule:
    """iCalendar-compatible recurrence information."""

    rrule: str
    exdates: List[str] = field(default_factory=list)
    rdates: List[str] = field(default_factory=list)


@dataclass
class SourceRef:
    """External identity retained for imported or synchronized items."""

    provider: str
    external_id: Optional[str] = None
    subscription_id: Optional[str] = None
    etag: Optional[str] = None
    url: Optional[str] = None


@dataclass
class ReminderSuggestion:
    """A reminder suggestion attached to a candidate item."""

    mode: ReminderMode = ReminderMode.RELATIVE
    minutes_before: Optional[int] = None
    remind_at: Optional[datetime] = None
    enabled: bool = True
    reason: Optional[str] = None


@dataclass
class Reminder:
    """A reminder belonging to a formal item."""

    id: str
    item_id: str
    mode: ReminderMode
    minutes_before: Optional[int] = None
    remind_at: Optional[datetime] = None
    enabled: bool = True


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


@dataclass
class Item:
    """A confirmed, persistable schedule event, task, or note."""

    id: str
    collection_id: str
    type: ItemType
    title: str
    body: Optional[str] = None
    start_at: Optional[datetime] = None
    end_at: Optional[datetime] = None
    due_at: Optional[datetime] = None
    timezone: Optional[str] = "Asia/Shanghai"
    all_day: bool = False
    location: Optional[str] = None
    status: ItemStatus = ItemStatus.TODO
    priority: Optional[int] = None
    recurrence: Optional[RecurrenceRule] = None
    reminders: List[Reminder] = field(default_factory=list)
    tags: List[str] = field(default_factory=list)
    source: ItemSource = ItemSource.LOCAL
    source_ref: Optional[SourceRef] = None
    metadata: Dict[str, Any] = field(default_factory=dict)
    created_at: datetime = field(default_factory=_utc_now)
    updated_at: datetime = field(default_factory=_utc_now)
    deleted_at: Optional[datetime] = None
    version: int = 1

    def __post_init__(self) -> None:
        self.type = ItemType(self.type)
        self.status = ItemStatus(self.status)
        self.source = ItemSource(self.source)

        if not self.title.strip():
            raise ValueError("Item title cannot be empty")
        if self.priority is not None and self.priority not in range(4):
            raise ValueError("Item priority must be between 0 and 3")
        if self.start_at and self.end_at and self.end_at < self.start_at:
            raise ValueError("Item end_at cannot be before start_at")
        if self.version < 1:
            raise ValueError("Item version must be at least 1")


@dataclass
class CandidateItem:
    """An unconfirmed item produced by a parser or assistant."""

    temp_id: str
    type: ItemType
    title: str
    body: Optional[str] = None
    start_at: Optional[datetime] = None
    end_at: Optional[datetime] = None
    due_at: Optional[datetime] = None
    timezone: Optional[str] = "Asia/Shanghai"
    location: Optional[str] = None
    attendees: List[str] = field(default_factory=list)
    reminders: List[ReminderSuggestion] = field(default_factory=list)
    confidence: float = 1.0
    reasoning: Optional[str] = None
    source_text_span: Optional[SourceTextSpan] = None
    priority: Optional[int] = None
    recurrence: Optional[RecurrenceRule] = None

    def __post_init__(self) -> None:
        self.type = ItemType(self.type)

        if not self.title.strip():
            raise ValueError("Candidate title cannot be empty")
        if not 0.0 <= self.confidence <= 1.0:
            raise ValueError("Candidate confidence must be between 0 and 1")
        if self.priority is not None and self.priority not in range(4):
            raise ValueError("Candidate priority must be between 0 and 3")
        if self.start_at and self.end_at and self.end_at < self.start_at:
            raise ValueError("Candidate end_at cannot be before start_at")

    def to_item(
        self,
        collection_id: str,
        item_id: str,
        *,
        source: ItemSource = ItemSource.AI,
        now: Optional[datetime] = None,
    ) -> Item:
        """Promote this candidate into a formal item after user confirmation."""
        timestamp = now or _utc_now()
        reminders = [
            Reminder(
                id=f"{item_id}:reminder:{index}",
                item_id=item_id,
                mode=suggestion.mode,
                minutes_before=suggestion.minutes_before,
                remind_at=suggestion.remind_at,
                enabled=suggestion.enabled,
            )
            for index, suggestion in enumerate(self.reminders)
        ]

        return Item(
            id=item_id,
            collection_id=collection_id,
            type=self.type,
            title=self.title,
            body=self.body,
            start_at=self.start_at,
            end_at=self.end_at,
            due_at=self.due_at,
            timezone=self.timezone,
            location=self.location,
            priority=self.priority,
            recurrence=self.recurrence,
            reminders=reminders,
            source=source,
            metadata={
                "candidate_temp_id": self.temp_id,
                "attendees": list(self.attendees),
            },
            created_at=timestamp,
            updated_at=timestamp,
        )
