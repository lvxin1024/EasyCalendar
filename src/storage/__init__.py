"""Durable storage adapters and repository contracts."""

from .repository import (
    CandidateConfirmationRecord,
    CandidateExtractionRecord,
    ConstraintViolationError,
    EntityAlreadyExistsError,
    EntityNotFoundError,
    IdempotencyRecord,
    ItemPosition,
    ItemQuery,
    ReminderScheduleRecord,
    ReminderScheduleState,
    RepositoryError,
    StorageDataError,
    SubscriptionFetchRecord,
    VersionConflictError,
)
from .sqlite import LATEST_SCHEMA_VERSION, SQLiteRepository, SQLiteSession

__all__ = [
    "CandidateConfirmationRecord",
    "CandidateExtractionRecord",
    "ConstraintViolationError",
    "EntityAlreadyExistsError",
    "EntityNotFoundError",
    "IdempotencyRecord",
    "ItemPosition",
    "ItemQuery",
    "LATEST_SCHEMA_VERSION",
    "RepositoryError",
    "ReminderScheduleRecord",
    "ReminderScheduleState",
    "SQLiteRepository",
    "SQLiteSession",
    "StorageDataError",
    "SubscriptionFetchRecord",
    "VersionConflictError",
]
