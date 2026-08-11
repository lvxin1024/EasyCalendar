"""Repository contracts and errors shared by storage adapters."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Optional

from src.domain import ItemStatus, ItemType


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
