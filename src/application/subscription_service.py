"""Subscription and read-only Collection use cases."""

from __future__ import annotations

import hashlib
import json
from dataclasses import asdict, dataclass, is_dataclass
from datetime import datetime, timezone
from enum import Enum
from typing import Any, Callable, Mapping, Optional
from uuid import uuid4

from src.domain import (
    ChangeOperation,
    Collection,
    CollectionKind,
    OutboxEntry,
    Subscription,
    SubscriptionType,
    SyncChange,
    SyncEntityType,
)
from src.storage import IdempotencyRecord, ItemQuery, VersionConflictError

from .errors import (
    CollectionNotFoundError,
    IdempotencyConflictError,
    InvalidCommandError,
    ReadonlyCollectionError,
    SubscriptionNotFoundError,
)
from .ports import SubscriptionRepositoryPort


@dataclass(frozen=True)
class CreateCollectionCommand:
    name: str
    id: Optional[str] = None
    kind: CollectionKind = CollectionKind.LOCAL
    color: Optional[str] = None
    metadata: dict[str, Any] | None = None


@dataclass(frozen=True)
class UpdateCollectionCommand:
    expected_version: int
    values: Mapping[str, Any]


@dataclass(frozen=True)
class CreateSubscriptionCommand:
    url: str
    title: str
    id: Optional[str] = None
    type: SubscriptionType = SubscriptionType.ICS
    enabled: bool = True
    metadata: dict[str, Any] | None = None


@dataclass(frozen=True)
class UpdateSubscriptionCommand:
    expected_version: int
    values: Mapping[str, Any]


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _id(prefix: str) -> str:
    return f"{prefix}_{uuid4().hex}"


class SubscriptionService:
    """Own subscription lifecycle and the read-only collection boundary."""

    def __init__(
        self,
        repository: SubscriptionRepositoryPort,
        *,
        device_id: str,
        clock: Callable[[], datetime] = _utc_now,
        id_factory: Callable[[str], str] = _id,
    ):
        if not isinstance(device_id, str) or not device_id.strip():
            raise ValueError("device_id cannot be empty")
        self.repository = repository
        self.device_id = device_id.strip()
        self._clock = clock
        self._id_factory = id_factory

    def list_collections(self, *, include_deleted: bool = False) -> list[Collection]:
        return self.repository.list_collections(include_deleted=include_deleted)

    def get_collection(
        self, collection_id: str, *, include_deleted: bool = False
    ) -> Collection:
        collection = self.repository.get_collection(
            collection_id, include_deleted=include_deleted
        )
        if collection is None:
            raise CollectionNotFoundError(f"Collection {collection_id!r} was not found")
        return collection

    def create_collection(
        self, command: CreateCollectionCommand, *, idempotency_key: str
    ) -> Collection:
        self._require_key(idempotency_key)
        if command.kind is not CollectionKind.LOCAL:
            raise InvalidCommandError(
                "Only local Collections can be created directly"
            )
        timestamp = self._now()
        request_hash = self._request_hash(command)
        collection_id = command.id or self._id_factory("collection")
        try:
            collection = Collection(
                id=collection_id,
                name=command.name,
                kind=command.kind,
                color=command.color,
                metadata=dict(command.metadata or {}),
                created_at=timestamp,
                updated_at=timestamp,
            )
        except ValueError as error:
            raise InvalidCommandError(str(error)) from error
        with self.repository.transaction() as transaction:
            replay = self._replay(transaction, "collections:create", idempotency_key, request_hash, Collection)
            if replay is not None:
                return replay
            transaction.create_collection(collection)
            transaction.create_outbox_entry(
                self._outbox(collection, SyncEntityType.COLLECTION, ChangeOperation.CREATE, timestamp)
            )
            self._record(transaction, "collections:create", idempotency_key, request_hash, collection, timestamp)
        return collection

    def update_collection(self, collection_id: str, command: UpdateCollectionCommand) -> Collection:
        self._require_version(command.expected_version)
        timestamp = self._now()
        with self.repository.transaction() as transaction:
            current = transaction.get_collection(collection_id)
            if current is None:
                raise CollectionNotFoundError(f"Collection {collection_id!r} was not found")
            self._require_local(current)
            if current.version != command.expected_version:
                raise VersionConflictError("Collection", collection_id, command.expected_version, current.version)
            values = dict(command.values)
            unknown = set(values) - {"name", "color", "metadata"}
            if unknown:
                raise InvalidCommandError(f"Unsupported Collection fields: {', '.join(sorted(unknown))}")
            data = current.to_dict()
            data.update(values)
            try:
                updated = Collection.from_dict(data)
                if updated != current:
                    updated.record_update(now=timestamp)
            except ValueError as error:
                raise InvalidCommandError(str(error)) from error
            if updated == current:
                return current
            transaction.update_collection(updated, expected_version=command.expected_version)
            transaction.create_outbox_entry(
                self._outbox(updated, SyncEntityType.COLLECTION, ChangeOperation.UPDATE, timestamp)
            )
            return updated

    def delete_collection(self, collection_id: str, *, expected_version: int) -> Collection:
        self._require_version(expected_version)
        timestamp = self._now()
        with self.repository.transaction() as transaction:
            current = transaction.get_collection(collection_id, include_deleted=True)
            if current is None:
                raise CollectionNotFoundError(f"Collection {collection_id!r} was not found")
            if current.is_deleted:
                return current
            self._require_local(current)
            if transaction.list_items(ItemQuery(collection_id=collection_id, limit=1)):
                raise InvalidCommandError("Collection must be empty before deletion")
            if transaction.list_subscriptions():
                active = [s for s in transaction.list_subscriptions() if s.collection_id == collection_id]
                if active:
                    raise InvalidCommandError("Delete the Subscription before its Collection")
            if current.version != expected_version:
                raise VersionConflictError("Collection", collection_id, expected_version, current.version)
            deleted = Collection.from_dict(current.to_dict())
            deleted.soft_delete(now=timestamp)
            transaction.update_collection(deleted, expected_version=expected_version)
            transaction.create_outbox_entry(
                self._outbox(deleted, SyncEntityType.COLLECTION, ChangeOperation.DELETE, timestamp)
            )
            return deleted

    def list_subscriptions(self, *, include_deleted: bool = False) -> list[Subscription]:
        return self.repository.list_subscriptions(include_deleted=include_deleted)

    def get_subscription(
        self, subscription_id: str, *, include_deleted: bool = False
    ) -> Subscription:
        subscription = self.repository.get_subscription(
            subscription_id, include_deleted=include_deleted
        )
        if subscription is None:
            raise SubscriptionNotFoundError(
                f"Subscription {subscription_id!r} was not found"
            )
        return subscription

    def create_subscription(
        self, command: CreateSubscriptionCommand, *, idempotency_key: str
    ) -> Subscription:
        self._require_key(idempotency_key)
        if command.type is not SubscriptionType.ICS:
            raise InvalidCommandError("Only ICS subscriptions are supported")
        timestamp = self._now()
        request_hash = self._request_hash(command)
        subscription_id = command.id or self._id_factory("subscription")
        collection_id = self._id_factory("collection")
        try:
            collection = Collection(
                id=collection_id,
                name=command.title,
                kind=CollectionKind.SUBSCRIPTION,
                readonly=True,
                created_at=timestamp,
                updated_at=timestamp,
            )
            subscription = Subscription(
                id=subscription_id,
                collection_id=collection_id,
                url=command.url,
                title=command.title,
                type=command.type,
                enabled=command.enabled,
                metadata=dict(command.metadata or {}),
                created_at=timestamp,
                updated_at=timestamp,
            )
        except ValueError as error:
            raise InvalidCommandError(str(error)) from error
        with self.repository.transaction() as transaction:
            replay = self._replay(transaction, "subscriptions:create", idempotency_key, request_hash, Subscription)
            if replay is not None:
                return replay
            transaction.create_collection(collection)
            transaction.create_subscription(subscription)
            transaction.create_outbox_entry(
                self._outbox(collection, SyncEntityType.COLLECTION, ChangeOperation.CREATE, timestamp)
            )
            transaction.create_outbox_entry(
                self._outbox(subscription, SyncEntityType.SUBSCRIPTION, ChangeOperation.CREATE, timestamp)
            )
            self._record(transaction, "subscriptions:create", idempotency_key, request_hash, subscription, timestamp)
        return subscription

    def update_subscription(self, subscription_id: str, command: UpdateSubscriptionCommand) -> Subscription:
        self._require_version(command.expected_version)
        timestamp = self._now()
        with self.repository.transaction() as transaction:
            current = transaction.get_subscription(subscription_id)
            if current is None:
                raise SubscriptionNotFoundError(f"Subscription {subscription_id!r} was not found")
            if current.version != command.expected_version:
                raise VersionConflictError("Subscription", subscription_id, command.expected_version, current.version)
            values = dict(command.values)
            unknown = set(values) - {"title", "url", "enabled", "metadata", "refresh_interval_minutes"}
            if unknown:
                raise InvalidCommandError(f"Unsupported Subscription fields: {', '.join(sorted(unknown))}")
            data = current.to_dict()
            metadata = dict(current.metadata)
            if "refresh_interval_minutes" in values:
                interval = values.pop("refresh_interval_minutes")
                if type(interval) is not int or not 1 <= interval <= 10080:
                    raise InvalidCommandError("refresh_interval_minutes must be between 1 and 10080")
                metadata["refresh_interval_minutes"] = interval
            if "metadata" in values:
                metadata.update(values.pop("metadata") or {})
            if metadata != current.metadata:
                data["metadata"] = metadata
            data.update(values)
            if data.get("url") != current.url:
                data.update(
                    last_fetched_at=None,
                    last_success_at=None,
                    last_error=None,
                    etag=None,
                    last_modified=None,
                    source_hash=None,
                )
            try:
                updated = Subscription.from_dict(data)
                if updated != current:
                    updated.record_update(now=timestamp)
            except ValueError as error:
                raise InvalidCommandError(str(error)) from error
            if updated == current:
                return current
            transaction.update_subscription(updated, expected_version=command.expected_version)
            transaction.create_outbox_entry(
                self._outbox(updated, SyncEntityType.SUBSCRIPTION, ChangeOperation.UPDATE, timestamp)
            )
            return updated

    def delete_subscription(self, subscription_id: str, *, expected_version: int) -> Subscription:
        self._require_version(expected_version)
        timestamp = self._now()
        with self.repository.transaction() as transaction:
            current = transaction.get_subscription(subscription_id, include_deleted=True)
            if current is None:
                raise SubscriptionNotFoundError(f"Subscription {subscription_id!r} was not found")
            if current.is_deleted:
                return current
            if current.version != expected_version:
                raise VersionConflictError("Subscription", subscription_id, expected_version, current.version)
            deleted = Subscription.from_dict(current.to_dict())
            deleted.soft_delete(now=timestamp)
            transaction.update_subscription(deleted, expected_version=expected_version)
            transaction.create_outbox_entry(
                self._outbox(deleted, SyncEntityType.SUBSCRIPTION, ChangeOperation.DELETE, timestamp)
            )
            return deleted

    @staticmethod
    def _require_local(collection: Collection) -> None:
        if collection.readonly or collection.kind is not CollectionKind.LOCAL:
            raise ReadonlyCollectionError(f"Collection {collection.id!r} is readonly")

    @staticmethod
    def _require_version(version: int) -> None:
        if type(version) is not int or version < 1:
            raise InvalidCommandError("expected_version must be at least 1")

    @staticmethod
    def _require_key(key: str) -> None:
        if not isinstance(key, str) or not key.strip():
            raise InvalidCommandError("Idempotency-Key is required")
        if len(key.strip()) > 200:
            raise InvalidCommandError("Idempotency-Key cannot exceed 200 characters")

    def _now(self) -> datetime:
        value = self._clock()
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("SubscriptionService clock must return an aware datetime")
        return value

    def _outbox(self, entity: Any, entity_type: SyncEntityType, operation: ChangeOperation, timestamp: datetime) -> OutboxEntry:
        return OutboxEntry(
            change=SyncChange(
                change_id=self._id_factory("change"),
                device_id=self.device_id,
                entity_type=entity_type,
                entity_id=entity.id,
                operation=operation,
                version=entity.version,
                updated_at=entity.updated_at,
                payload=entity.to_dict(),
            ),
            created_at=timestamp,
        )

    @staticmethod
    def _request_hash(value: Any) -> str:
        canonical = json.dumps(SubscriptionService._jsonable(value), ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        return hashlib.sha256(canonical.encode("utf-8")).hexdigest()

    @staticmethod
    def _jsonable(value: Any) -> Any:
        if is_dataclass(value):
            return SubscriptionService._jsonable(asdict(value))
        if isinstance(value, Enum):
            return value.value
        if isinstance(value, datetime):
            return value.isoformat()
        if isinstance(value, Mapping):
            return {str(key): SubscriptionService._jsonable(item) for key, item in value.items()}
        if isinstance(value, (list, tuple)):
            return [SubscriptionService._jsonable(item) for item in value]
        return value

    @staticmethod
    def _replay(transaction: Any, scope: str, key: str, request_hash: str, model: Any) -> Any:
        record = transaction.get_idempotency_record(scope, key.strip())
        if record is None:
            return None
        if record.request_hash != request_hash:
            raise IdempotencyConflictError("Idempotency-Key was already used for a different request")
        try:
            return model.from_json(record.response_json)
        except ValueError as error:
            raise InvalidCommandError("Stored idempotent response is invalid") from error

    @staticmethod
    def _record(transaction: Any, scope: str, key: str, request_hash: str, value: Any, timestamp: datetime) -> None:
        transaction.create_idempotency_record(
            IdempotencyRecord(
                scope=scope,
                key=key.strip(),
                request_hash=request_hash,
                response_json=value.to_json(),
                created_at=timestamp,
            )
        )
