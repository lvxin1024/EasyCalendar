"""Core data models for the single-user schedule and due app."""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from typing import Any, ClassVar, Dict, List, Optional
from urllib.parse import urlsplit
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from .serialization import SerializableDomainModel, ensure_json_value


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


class CollectionKind(str, Enum):
    """Ownership model for a collection."""

    LOCAL = "local"
    SUBSCRIPTION = "subscription"
    EXTERNAL = "external"


class SubscriptionType(str, Enum):
    """Kinds of read-only subscription sources."""

    ICS = "ics"


class SyncEntityType(str, Enum):
    """Entity types transported by synchronization."""

    ITEM = "item"
    COLLECTION = "collection"
    SUBSCRIPTION = "subscription"


class ChangeOperation(str, Enum):
    """Operations represented by a synchronization change."""

    CREATE = "create"
    UPDATE = "update"
    DELETE = "delete"


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _require_nonempty(value: str, field_name: str) -> str:
    if not isinstance(value, str):
        raise ValueError(f"{field_name} must be a string")
    normalized = value.strip()
    if not normalized:
        raise ValueError(f"{field_name} cannot be empty")
    return normalized


def _require_aware(value: datetime, field_name: str) -> None:
    if not isinstance(value, datetime):
        raise ValueError(f"{field_name} must be a datetime")
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError(f"{field_name} must include a timezone")


def _normalize_timezone_name(value: Optional[str]) -> Optional[str]:
    if value is None:
        return None
    normalized = _require_nonempty(value, "Item timezone")
    try:
        ZoneInfo(normalized)
    except ZoneInfoNotFoundError as error:
        raise ValueError(f"Unknown item timezone: {normalized}") from error
    return normalized


def _normalize_schedule_time(
    value: Optional[datetime], timezone_name: Optional[str], field_name: str
) -> Optional[datetime]:
    if value is not None and not isinstance(value, datetime):
        raise ValueError(f"{field_name} must be a datetime")
    if value is None or (value.tzinfo is not None and value.utcoffset() is not None):
        return value
    if not timezone_name:
        raise ValueError(f"{field_name} requires an item timezone")
    return value.replace(tzinfo=ZoneInfo(timezone_name))


def _validate_time_order(
    start_at: Optional[datetime], end_at: Optional[datetime], model_name: str
) -> None:
    for field_name, value in (("start_at", start_at), ("end_at", end_at)):
        if value is not None and not isinstance(value, datetime):
            raise ValueError(f"{model_name} {field_name} must be a datetime")
    if end_at is not None and start_at is None:
        raise ValueError(f"{model_name} end_at requires start_at")
    if start_at is None or end_at is None:
        return
    try:
        if end_at < start_at:
            raise ValueError(f"{model_name} end_at cannot be before start_at")
    except TypeError as error:
        raise ValueError(
            f"{model_name} start_at and end_at must use compatible timezones"
        ) from error


def _validate_versioned(entity: _VersionedEntity, model_name: str) -> None:
    entity.id = _require_nonempty(entity.id, f"{model_name} id")
    if type(entity.version) is not int or entity.version < 1:
        raise ValueError(f"{model_name} version must be at least 1")
    _require_aware(entity.created_at, f"{model_name} created_at")
    _require_aware(entity.updated_at, f"{model_name} updated_at")
    if entity.updated_at < entity.created_at:
        raise ValueError(f"{model_name} updated_at cannot be before created_at")
    if entity.deleted_at is not None:
        _require_aware(entity.deleted_at, f"{model_name} deleted_at")
        if entity.deleted_at < entity.created_at:
            raise ValueError(f"{model_name} deleted_at cannot be before created_at")
        if entity.updated_at < entity.deleted_at:
            raise ValueError(f"{model_name} updated_at cannot be before deleted_at")


class _VersionedEntity(SerializableDomainModel):
    """Shared lifecycle behavior for persisted, synchronized entities."""

    id: str
    created_at: datetime
    updated_at: datetime
    deleted_at: Optional[datetime]
    version: int

    @property
    def is_deleted(self) -> bool:
        return self.deleted_at is not None

    def _transition_at(self, now: Optional[datetime]) -> datetime:
        timestamp = now or _utc_now()
        _require_aware(timestamp, "transition timestamp")
        if timestamp < self.updated_at:
            raise ValueError("Transition timestamp cannot be before updated_at")
        return timestamp

    def _advance_version(self, timestamp: datetime) -> int:
        self.updated_at = timestamp
        self.version += 1
        return self.version

    def record_update(self, *, now: Optional[datetime] = None) -> int:
        """Record a successful formal update and increment the entity version."""
        if self.is_deleted:
            raise ValueError("Deleted entities must be restored before updating")
        return self._advance_version(self._transition_at(now))

    def soft_delete(self, *, now: Optional[datetime] = None) -> bool:
        """Create a deletion tombstone once; repeated deletes are idempotent."""
        if self.is_deleted:
            return False
        timestamp = self._transition_at(now)
        self.deleted_at = timestamp
        self._advance_version(timestamp)
        return True

    def restore(self, *, now: Optional[datetime] = None) -> bool:
        """Restore a tombstone once and increment the entity version."""
        if not self.is_deleted:
            return False
        timestamp = self._transition_at(now)
        self.deleted_at = None
        self._advance_version(timestamp)
        return True


@dataclass
class SourceTextSpan(SerializableDomainModel):
    """Character offsets for the text that produced a candidate."""

    json_model: ClassVar[str] = "source_text_span"

    start: int
    end: int

    def __post_init__(self) -> None:
        if type(self.start) is not int or type(self.end) is not int:
            raise ValueError("SourceTextSpan offsets must be integers")
        if self.start < 0:
            raise ValueError("SourceTextSpan start cannot be negative")
        if self.end < self.start:
            raise ValueError("SourceTextSpan end cannot be before start")


@dataclass
class RecurrenceRule(SerializableDomainModel):
    """iCalendar-compatible recurrence information."""

    json_model: ClassVar[str] = "recurrence_rule"

    rrule: str
    exdates: List[str] = field(default_factory=list)
    rdates: List[str] = field(default_factory=list)

    def __post_init__(self) -> None:
        self.rrule = _require_nonempty(self.rrule, "RecurrenceRule rrule")
        if not isinstance(self.exdates, list) or not isinstance(self.rdates, list):
            raise ValueError("RecurrenceRule dates must be arrays")
        if any(not isinstance(value, str) or not value.strip() for value in self.exdates):
            raise ValueError("RecurrenceRule exdates must be non-empty strings")
        if any(not isinstance(value, str) or not value.strip() for value in self.rdates):
            raise ValueError("RecurrenceRule rdates must be non-empty strings")


@dataclass
class SourceRef(SerializableDomainModel):
    """External identity retained for imported or synchronized items."""

    json_model: ClassVar[str] = "source_ref"

    provider: str
    external_id: Optional[str] = None
    subscription_id: Optional[str] = None
    etag: Optional[str] = None
    url: Optional[str] = None

    def __post_init__(self) -> None:
        self.provider = _require_nonempty(self.provider, "SourceRef provider")
        for field_name in ("external_id", "subscription_id", "etag", "url"):
            value = getattr(self, field_name)
            if value is not None and not isinstance(value, str):
                raise ValueError(f"SourceRef {field_name} must be a string")


@dataclass
class ReminderSuggestion(SerializableDomainModel):
    """A reminder suggestion attached to a candidate item."""

    json_model: ClassVar[str] = "reminder_suggestion"

    mode: ReminderMode = ReminderMode.RELATIVE
    minutes_before: Optional[int] = None
    remind_at: Optional[datetime] = None
    enabled: bool = True
    reason: Optional[str] = None

    def __post_init__(self) -> None:
        self.mode = ReminderMode(self.mode)
        if type(self.enabled) is not bool:
            raise ValueError("ReminderSuggestion enabled must be a boolean")
        if self.minutes_before is not None and (
            type(self.minutes_before) is not int or self.minutes_before < 0
        ):
            raise ValueError("ReminderSuggestion minutes_before cannot be negative")
        if self.mode is ReminderMode.RELATIVE and self.remind_at is not None:
            raise ValueError("Relative reminder suggestions cannot use remind_at")
        if self.mode is ReminderMode.ABSOLUTE:
            if self.remind_at is None:
                raise ValueError("Absolute reminder suggestions require remind_at")
            _require_aware(self.remind_at, "ReminderSuggestion remind_at")
            if self.minutes_before is not None:
                raise ValueError("Absolute reminder suggestions cannot use minutes_before")


@dataclass
class Reminder(SerializableDomainModel):
    """A reminder belonging to a formal item."""

    json_model: ClassVar[str] = "reminder"

    id: str
    item_id: str
    mode: ReminderMode
    minutes_before: Optional[int] = None
    remind_at: Optional[datetime] = None
    enabled: bool = True

    def __post_init__(self) -> None:
        self.id = _require_nonempty(self.id, "Reminder id")
        self.item_id = _require_nonempty(self.item_id, "Reminder item_id")
        self.mode = ReminderMode(self.mode)
        if type(self.enabled) is not bool:
            raise ValueError("Reminder enabled must be a boolean")
        if self.mode is ReminderMode.RELATIVE:
            if (
                type(self.minutes_before) is not int
                or self.minutes_before < 0
            ):
                raise ValueError(
                    "Relative reminders require non-negative minutes_before"
                )
            if self.remind_at is not None:
                raise ValueError("Relative reminders cannot use remind_at")
        else:
            if self.remind_at is None:
                raise ValueError("Absolute reminders require remind_at")
            _require_aware(self.remind_at, "Reminder remind_at")
            if self.minutes_before is not None:
                raise ValueError("Absolute reminders cannot use minutes_before")


@dataclass
class Item(_VersionedEntity):
    """A confirmed, persistable schedule event, task, or note."""

    json_model: ClassVar[str] = "item"

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
        self.id = _require_nonempty(self.id, "Item id")
        self.collection_id = _require_nonempty(
            self.collection_id, "Item collection_id"
        )
        self.type = ItemType(self.type)
        self.title = _require_nonempty(self.title, "Item title")
        self.status = ItemStatus(self.status)
        self.source = ItemSource(self.source)
        self.timezone = _normalize_timezone_name(self.timezone)
        if type(self.all_day) is not bool:
            raise ValueError("Item all_day must be a boolean")
        if self.priority is not None and (
            type(self.priority) is not int or self.priority not in range(4)
        ):
            raise ValueError("Item priority must be between 0 and 3")

        self.start_at = _normalize_schedule_time(
            self.start_at, self.timezone, "Item start_at"
        )
        self.end_at = _normalize_schedule_time(
            self.end_at, self.timezone, "Item end_at"
        )
        self.due_at = _normalize_schedule_time(
            self.due_at, self.timezone, "Item due_at"
        )
        _validate_time_order(self.start_at, self.end_at, "Item")
        if self.type is ItemType.EVENT and self.start_at is None:
            raise ValueError("Event items require start_at")

        if not isinstance(self.reminders, list) or not all(
            isinstance(reminder, Reminder) for reminder in self.reminders
        ):
            raise ValueError("Item reminders must contain Reminder objects")
        if any(reminder.item_id != self.id for reminder in self.reminders):
            raise ValueError("Item reminders must reference the owning item")
        if self.recurrence is not None and not isinstance(
            self.recurrence, RecurrenceRule
        ):
            raise ValueError("Item recurrence must be a RecurrenceRule")
        if self.source_ref is not None and not isinstance(self.source_ref, SourceRef):
            raise ValueError("Item source_ref must be a SourceRef")
        if not isinstance(self.tags, list) or not all(
            isinstance(tag, str) for tag in self.tags
        ):
            raise ValueError("Item tags must be strings")
        self.tags = list(
            dict.fromkeys(tag.strip() for tag in self.tags if tag.strip())
        )
        if not isinstance(self.metadata, dict):
            raise ValueError("Item metadata must be an object")
        ensure_json_value(self.metadata, "Item metadata")
        _validate_versioned(self, "Item")


@dataclass
class CandidateItem(SerializableDomainModel):
    """An unconfirmed item produced by a parser or assistant."""

    json_model: ClassVar[str] = "candidate_item"

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
        self.temp_id = _require_nonempty(self.temp_id, "Candidate temp_id")
        self.type = ItemType(self.type)
        self.title = _require_nonempty(self.title, "Candidate title")
        self.timezone = _normalize_timezone_name(self.timezone)
        if isinstance(self.confidence, bool) or not isinstance(
            self.confidence, (int, float)
        ):
            raise ValueError("Candidate confidence must be a number")
        self.confidence = float(self.confidence)
        if not 0.0 <= self.confidence <= 1.0:
            raise ValueError("Candidate confidence must be between 0 and 1")
        if self.priority is not None and (
            type(self.priority) is not int or self.priority not in range(4)
        ):
            raise ValueError("Candidate priority must be between 0 and 3")
        if self.due_at is not None and not isinstance(self.due_at, datetime):
            raise ValueError("Candidate due_at must be a datetime")
        _validate_time_order(self.start_at, self.end_at, "Candidate")
        if not isinstance(self.reminders, list) or not all(
            isinstance(reminder, ReminderSuggestion) for reminder in self.reminders
        ):
            raise ValueError(
                "Candidate reminders must contain ReminderSuggestion objects"
            )
        if self.recurrence is not None and not isinstance(
            self.recurrence, RecurrenceRule
        ):
            raise ValueError("Candidate recurrence must be a RecurrenceRule")
        if self.source_text_span is not None and not isinstance(
            self.source_text_span, SourceTextSpan
        ):
            raise ValueError("Candidate source_text_span must be a SourceTextSpan")
        if not isinstance(self.attendees, list) or not all(
            isinstance(attendee, str) for attendee in self.attendees
        ):
            raise ValueError("Candidate attendees must be strings")
        self.attendees = list(
            dict.fromkeys(
                attendee.strip() for attendee in self.attendees if attendee.strip()
            )
        )

    def to_item(
        self,
        collection_id: str,
        item_id: str,
        *,
        source: ItemSource = ItemSource.LOCAL,
        now: Optional[datetime] = None,
    ) -> Item:
        """Promote this candidate into a formal item after user confirmation."""
        timestamp = now or _utc_now()
        _require_aware(timestamp, "Candidate confirmation timestamp")
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


@dataclass
class Collection(_VersionedEntity):
    """A local, subscription-owned, or external item container."""

    json_model: ClassVar[str] = "collection"

    id: str
    name: str
    kind: CollectionKind = CollectionKind.LOCAL
    color: Optional[str] = None
    readonly: bool = False
    metadata: Dict[str, Any] = field(default_factory=dict)
    created_at: datetime = field(default_factory=_utc_now)
    updated_at: datetime = field(default_factory=_utc_now)
    deleted_at: Optional[datetime] = None
    version: int = 1

    def __post_init__(self) -> None:
        self.name = _require_nonempty(self.name, "Collection name")
        self.kind = CollectionKind(self.kind)
        if type(self.readonly) is not bool:
            raise ValueError("Collection readonly must be a boolean")
        if self.color is not None:
            if not isinstance(self.color, str) or not re.fullmatch(
                r"#[0-9A-Fa-f]{6}", self.color
            ):
                raise ValueError("Collection color must use #RRGGBB")
        if self.kind is CollectionKind.SUBSCRIPTION and not self.readonly:
            raise ValueError("Subscription collections must be readonly")
        if not isinstance(self.metadata, dict):
            raise ValueError("Collection metadata must be an object")
        ensure_json_value(self.metadata, "Collection metadata")
        _validate_versioned(self, "Collection")


@dataclass
class Subscription(_VersionedEntity):
    """Configuration and refresh state for a read-only calendar source."""

    json_model: ClassVar[str] = "subscription"

    id: str
    collection_id: str
    url: str
    title: str
    type: SubscriptionType = SubscriptionType.ICS
    enabled: bool = True
    last_fetched_at: Optional[datetime] = None
    last_success_at: Optional[datetime] = None
    last_error: Optional[str] = None
    etag: Optional[str] = None
    source_hash: Optional[str] = None
    metadata: Dict[str, Any] = field(default_factory=dict)
    created_at: datetime = field(default_factory=_utc_now)
    updated_at: datetime = field(default_factory=_utc_now)
    deleted_at: Optional[datetime] = None
    version: int = 1

    def __post_init__(self) -> None:
        self.collection_id = _require_nonempty(
            self.collection_id, "Subscription collection_id"
        )
        self.title = _require_nonempty(self.title, "Subscription title")
        self.type = SubscriptionType(self.type)
        if type(self.enabled) is not bool:
            raise ValueError("Subscription enabled must be a boolean")
        self.url = _require_nonempty(self.url, "Subscription url")
        parsed_url = urlsplit(self.url)
        if parsed_url.scheme not in {"http", "https"} or not parsed_url.hostname:
            raise ValueError("Subscription url must be an absolute HTTP(S) URL")
        for field_name in ("last_fetched_at", "last_success_at"):
            value = getattr(self, field_name)
            if value is not None:
                _require_aware(value, f"Subscription {field_name}")
        if self.last_success_at is not None and self.last_fetched_at is None:
            raise ValueError("Subscription last_success_at requires last_fetched_at")
        if (
            self.last_success_at is not None
            and self.last_fetched_at is not None
            and self.last_success_at > self.last_fetched_at
        ):
            raise ValueError(
                "Subscription last_success_at cannot be after last_fetched_at"
            )
        if not isinstance(self.metadata, dict):
            raise ValueError("Subscription metadata must be an object")
        ensure_json_value(self.metadata, "Subscription metadata")
        _validate_versioned(self, "Subscription")

    def set_enabled(self, enabled: bool, *, now: Optional[datetime] = None) -> bool:
        if self.is_deleted:
            raise ValueError("Deleted subscriptions cannot be changed")
        if type(enabled) is not bool:
            raise ValueError("Subscription enabled must be a boolean")
        if self.enabled is enabled:
            return False
        timestamp = self._transition_at(now)
        self.enabled = enabled
        self._advance_version(timestamp)
        return True

    def record_success(
        self,
        *,
        etag: Optional[str] = None,
        source_hash: Optional[str] = None,
        now: Optional[datetime] = None,
    ) -> None:
        if self.is_deleted:
            raise ValueError("Deleted subscriptions cannot be refreshed")
        timestamp = self._transition_at(now)
        self.last_fetched_at = timestamp
        self.last_success_at = timestamp
        self.last_error = None
        self.etag = etag
        self.source_hash = source_hash
        self._advance_version(timestamp)

    def record_failure(self, error: str, *, now: Optional[datetime] = None) -> None:
        if self.is_deleted:
            raise ValueError("Deleted subscriptions cannot be refreshed")
        message = _require_nonempty(error, "Subscription error")
        timestamp = self._transition_at(now)
        self.last_fetched_at = timestamp
        self.last_error = message
        self._advance_version(timestamp)


@dataclass
class SyncChange(SerializableDomainModel):
    """An idempotent entity change transported between devices and server."""

    json_model: ClassVar[str] = "sync_change"

    change_id: str
    device_id: str
    entity_type: SyncEntityType
    entity_id: str
    operation: ChangeOperation
    version: int
    updated_at: datetime
    payload: Dict[str, Any] = field(default_factory=dict)

    def __post_init__(self) -> None:
        self.change_id = _require_nonempty(self.change_id, "SyncChange change_id")
        self.device_id = _require_nonempty(self.device_id, "SyncChange device_id")
        self.entity_id = _require_nonempty(self.entity_id, "SyncChange entity_id")
        self.entity_type = SyncEntityType(self.entity_type)
        self.operation = ChangeOperation(self.operation)
        if type(self.version) is not int or self.version < 1:
            raise ValueError("SyncChange version must be at least 1")
        _require_aware(self.updated_at, "SyncChange updated_at")
        if not isinstance(self.payload, dict):
            raise ValueError("SyncChange payload must be an object")
        ensure_json_value(self.payload, "SyncChange payload")

    @property
    def conflict_order(self) -> tuple[datetime, int, str]:
        return (self.updated_at, self.version, self.change_id)

    def wins_over(self, other: SyncChange) -> bool:
        if not isinstance(other, SyncChange):
            raise ValueError("Can only compare another SyncChange")
        if (
            self.entity_type is not other.entity_type
            or self.entity_id != other.entity_id
        ):
            raise ValueError("Cannot compare changes for different entities")
        return self.conflict_order > other.conflict_order


@dataclass
class OutboxEntry(SerializableDomainModel):
    """Local delivery state for one synchronization change."""

    json_model: ClassVar[str] = "outbox_entry"

    change: SyncChange
    created_at: datetime = field(default_factory=_utc_now)
    retry_count: int = 0
    last_error: Optional[str] = None
    sent_at: Optional[datetime] = None

    def __post_init__(self) -> None:
        if not isinstance(self.change, SyncChange):
            raise ValueError("OutboxEntry change must be a SyncChange")
        _require_aware(self.created_at, "OutboxEntry created_at")
        if type(self.retry_count) is not int or self.retry_count < 0:
            raise ValueError("OutboxEntry retry_count cannot be negative")
        if self.sent_at is not None:
            _require_aware(self.sent_at, "OutboxEntry sent_at")
            if self.sent_at < self.created_at:
                raise ValueError("OutboxEntry sent_at cannot be before created_at")
            if self.last_error is not None:
                raise ValueError("Sent outbox entries cannot retain last_error")

    @property
    def is_pending(self) -> bool:
        return self.sent_at is None

    def record_failure(self, error: str) -> None:
        if not self.is_pending:
            raise ValueError("Sent outbox entries cannot record failures")
        self.last_error = _require_nonempty(error, "OutboxEntry error")
        self.retry_count += 1

    def mark_sent(self, *, now: Optional[datetime] = None) -> bool:
        if not self.is_pending:
            return False
        timestamp = now or _utc_now()
        _require_aware(timestamp, "OutboxEntry sent_at")
        if timestamp < self.created_at:
            raise ValueError("OutboxEntry sent_at cannot be before created_at")
        self.sent_at = timestamp
        self.last_error = None
        return True
