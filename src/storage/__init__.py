"""Durable storage adapters and repository contracts."""

from .repository import (
    ConstraintViolationError,
    EntityAlreadyExistsError,
    EntityNotFoundError,
    IdempotencyRecord,
    ItemPosition,
    ItemQuery,
    RepositoryError,
    StorageDataError,
    VersionConflictError,
)
from .sqlite import LATEST_SCHEMA_VERSION, SQLiteRepository, SQLiteSession

__all__ = [
    "ConstraintViolationError",
    "EntityAlreadyExistsError",
    "EntityNotFoundError",
    "IdempotencyRecord",
    "ItemPosition",
    "ItemQuery",
    "LATEST_SCHEMA_VERSION",
    "RepositoryError",
    "SQLiteRepository",
    "SQLiteSession",
    "StorageDataError",
    "VersionConflictError",
]
