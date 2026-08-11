"""Repository contracts and errors shared by storage adapters."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from enum import Enum
from typing import Optional

from src.domain import CandidateItem, ItemStatus, ItemType


class RepositoryError(RuntimeError):
    """Base error for durable storage operations."""


class EntityAlreadyExistsError(RepositoryError):
    """Raised when an insert reuses an existing entity identifier."""


class EntityNotFoundError(RepositoryError):
    """Raised when an entity to update no longer exists."""


class ConstraintViolationError(RepositoryError):
    """Raised when an entity references missing or incompatible stored data."""


class VersionConflictError(RepositoryError):
    """Raised when an optimistic write uses a stale version."""

    def __init__(self, entity_type: str, entity_id: str, expected: int, actual: int):
        self.entity_type = entity_type
        self.entity_id = entity_id
        self.expected = expected
        self.actual = actual
        super().__init__(
            f"{entity_type} {entity_id!r} version conflict: "
            f"expected {expected}, found {actual}"
        )


class StorageDataError(RepositoryError):
    """Raised when persisted data cannot satisfy the domain contract."""


class ReminderScheduleState(str, Enum):
    """Result of the latest platform scheduling attempt."""

    SCHEDULED = "scheduled"
    FAILED = "failed"


@dataclass(frozen=True)
class ItemPosition:
    """Stable keyset position in the mixed Event, Task, and Note ordering."""

    schedule_at: Optional[datetime]
    item_id: str

    def __post_init__(self) -> None:
        if self.schedule_at is not None and (
            not isinstance(self.schedule_at, datetime)
            or self.schedule_at.tzinfo is None
            or self.schedule_at.utcoffset() is None
        ):
            raise ValueError("ItemPosition schedule_at must include a timezone")
        if not isinstance(self.item_id, str) or not self.item_id.strip():
            raise ValueError("ItemPosition item_id cannot be empty")


@dataclass(frozen=True)
class IdempotencyRecord:
    """Persisted command result used to make retries deterministic."""

    scope: str
    key: str
    request_hash: str
    response_json: str
    created_at: datetime

    def __post_init__(self) -> None:
        for field_name in ("scope", "key", "request_hash", "response_json"):
            value = getattr(self, field_name)
            if not isinstance(value, str) or not value.strip():
                raise ValueError(f"IdempotencyRecord {field_name} cannot be empty")
        if self.created_at.tzinfo is None or self.created_at.utcoffset() is None:
            raise ValueError("IdempotencyRecord created_at must include a timezone")


@dataclass(frozen=True)
class CandidateExtractionRecord:
    """Persisted preview and optional rejection audit for parser output."""

    extraction_id: str
    parser_id: str
    source_text: str
    candidates: list[CandidateItem]
    warnings: list[str]
    created_at: datetime
    rejected_at: Optional[datetime] = None
    rejection_reason: Optional[str] = None

    def __post_init__(self) -> None:
        for field_name in ("extraction_id", "parser_id"):
            value = getattr(self, field_name)
            if not isinstance(value, str) or not value.strip():
                raise ValueError(
                    f"CandidateExtractionRecord {field_name} cannot be empty"
                )
        if not isinstance(self.source_text, str):
            raise ValueError("CandidateExtractionRecord source_text must be a string")
        if not isinstance(self.candidates, list) or not all(
            isinstance(candidate, CandidateItem) for candidate in self.candidates
        ):
            raise ValueError(
                "CandidateExtractionRecord candidates must contain CandidateItem values"
            )
        temp_ids = [candidate.temp_id for candidate in self.candidates]
        if len(temp_ids) != len(set(temp_ids)):
            raise ValueError("CandidateExtractionRecord temp_ids must be unique")
        if not isinstance(self.warnings, list) or not all(
            isinstance(warning, str) for warning in self.warnings
        ):
            raise ValueError("CandidateExtractionRecord warnings must be strings")
        for field_name in ("created_at", "rejected_at"):
            value = getattr(self, field_name)
            if value is not None and (
                value.tzinfo is None or value.utcoffset() is None
            ):
                raise ValueError(
                    f"CandidateExtractionRecord {field_name} must include a timezone"
                )
        if self.rejection_reason is not None and self.rejected_at is None:
            raise ValueError("rejection_reason requires rejected_at")


@dataclass(frozen=True)
class CandidateConfirmationRecord:
    """One immutable Candidate-to-Item decision."""

    extraction_id: str
    temp_id: str
    item_id: str
    request_hash: str
    confirmed_at: datetime

    def __post_init__(self) -> None:
        for field_name in ("extraction_id", "temp_id", "item_id", "request_hash"):
            value = getattr(self, field_name)
            if not isinstance(value, str) or not value.strip():
                raise ValueError(
                    f"CandidateConfirmationRecord {field_name} cannot be empty"
                )
        if self.confirmed_at.tzinfo is None or self.confirmed_at.utcoffset() is None:
            raise ValueError(
                "CandidateConfirmationRecord confirmed_at must include a timezone"
            )


@dataclass(frozen=True)
class ReminderScheduleRecord:
    """Persisted derived state for one platform notification."""

    reminder_id: str
    item_id: str
    item_version: int
    fire_at: datetime
    state: ReminderScheduleState
    platform_schedule_id: Optional[str]
    last_error: Optional[str]
    updated_at: datetime

    def __post_init__(self) -> None:
        for field_name in ("reminder_id", "item_id"):
            value = getattr(self, field_name)
            if not isinstance(value, str) or not value.strip():
                raise ValueError(
                    f"ReminderScheduleRecord {field_name} cannot be empty"
                )
        if type(self.item_version) is not int or self.item_version < 1:
            raise ValueError("ReminderScheduleRecord item_version must be at least 1")
        for field_name in ("fire_at", "updated_at"):
            value = getattr(self, field_name)
            if (
                not isinstance(value, datetime)
                or value.tzinfo is None
                or value.utcoffset() is None
            ):
                raise ValueError(
                    f"ReminderScheduleRecord {field_name} must include a timezone"
                )
        object.__setattr__(self, "state", ReminderScheduleState(self.state))
        if self.platform_schedule_id is not None and (
            not isinstance(self.platform_schedule_id, str)
            or not self.platform_schedule_id.strip()
        ):
            raise ValueError(
                "ReminderScheduleRecord platform_schedule_id cannot be blank"
            )
        if self.state is ReminderScheduleState.SCHEDULED:
            if self.platform_schedule_id is None:
                raise ValueError("Scheduled reminders require a platform_schedule_id")
            if self.last_error is not None:
                raise ValueError("Scheduled reminders cannot have last_error")
        elif not isinstance(self.last_error, str) or not self.last_error.strip():
            raise ValueError("Failed reminders require last_error")


@dataclass(frozen=True)
class ItemQuery:
    """Storage-level Item filters; HTTP pagination belongs to the service layer."""

    collection_id: Optional[str] = None
    item_type: Optional[ItemType] = None
    status: Optional[ItemStatus] = None
    from_at: Optional[datetime] = None
    to_at: Optional[datetime] = None
    after: Optional[ItemPosition] = None
    include_deleted: bool = False
    limit: int = 200

    def __post_init__(self) -> None:
        if self.collection_id is not None and not self.collection_id.strip():
            raise ValueError("ItemQuery collection_id cannot be empty")
        if self.item_type is not None:
            object.__setattr__(self, "item_type", ItemType(self.item_type))
        if self.status is not None:
            object.__setattr__(self, "status", ItemStatus(self.status))
        for field_name in ("from_at", "to_at"):
            value = getattr(self, field_name)
            if value is not None and (
                not isinstance(value, datetime)
                or value.tzinfo is None
                or value.utcoffset() is None
            ):
                raise ValueError(f"ItemQuery {field_name} must include a timezone")
        if self.from_at is not None and self.to_at is not None:
            if self.to_at < self.from_at:
                raise ValueError("ItemQuery to_at cannot be before from_at")
        if self.after is not None and not isinstance(self.after, ItemPosition):
            raise ValueError("ItemQuery after must be an ItemPosition")
        if type(self.include_deleted) is not bool:
            raise ValueError("ItemQuery include_deleted must be a boolean")
        if type(self.limit) is not int or self.limit < 1 or self.limit > 1000:
            raise ValueError("ItemQuery limit must be between 1 and 1000")
