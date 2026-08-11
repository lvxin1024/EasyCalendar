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
class ItemQuery:
    """Storage-level Item filters; HTTP pagination belongs to the service layer."""

    collection_id: Optional[str] = None
    item_type: Optional[ItemType] = None
    status: Optional[ItemStatus] = None
    from_at: Optional[datetime] = None
    to_at: Optional[datetime] = None
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
        if type(self.include_deleted) is not bool:
            raise ValueError("ItemQuery include_deleted must be a boolean")
        if type(self.limit) is not int or self.limit < 1 or self.limit > 1000:
            raise ValueError("ItemQuery limit must be between 1 and 1000")
