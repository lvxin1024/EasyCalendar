"""Item use cases with atomic outbox and persistent idempotency semantics."""

from __future__ import annotations

import base64
import binascii
import hashlib
import json
import logging
from dataclasses import asdict, dataclass, field, is_dataclass
from datetime import datetime, timezone
from enum import Enum
from typing import Any, Callable, Dict, List, Mapping, Optional
from uuid import uuid4

from src.domain import (
    ChangeOperation,
    CandidateItem,
    Collection,
    Item,
    ItemSource,
    ItemStatus,
    ItemType,
    OutboxEntry,
    RecurrenceRule,
    Reminder,
    ReminderMode,
    SyncChange,
    SyncEntityType,
)
from src.storage import (
    CandidateConfirmationRecord,
    IdempotencyRecord,
    ItemPosition,
    ItemQuery,
    VersionConflictError,
)
from src.domain.recurrence import expand_item

from .errors import (
    CandidateDecisionConflictError,
    CollectionNotFoundError,
    IdempotencyConflictError,
    InvalidCommandError,
    InvalidCursorError,
    ItemNotFoundError,
    ReadonlyCollectionError,
    ExtractionNotFoundError,
    ExtractionRejectedError,
)
from .ports import ItemRepositoryPort, ReminderCoordinatorPort


logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class ReminderDraft:
    mode: ReminderMode
    id: Optional[str] = None
    minutes_before: Optional[int] = None
    remind_at: Optional[datetime] = None
    enabled: bool = True


@dataclass(frozen=True)
class CreateItemCommand:
    collection_id: str
    type: ItemType
    title: str
    id: Optional[str] = None
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
    reminders: List[ReminderDraft] = field(default_factory=list)
    tags: List[str] = field(default_factory=list)
    source: ItemSource = ItemSource.LOCAL
    metadata: Dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class UpdateItemCommand:
    expected_version: int
    values: Mapping[str, Any]


@dataclass(frozen=True)
class CandidateEditCommand:
    collection_id: str
    values: Mapping[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class ItemPage:
    items: List[Item]
    next_cursor: Optional[str]
    has_more: bool


def _default_id_factory(prefix: str) -> str:
    return f"{prefix}_{uuid4().hex}"


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


class ItemService:
    """Own formal Item state transitions and their synchronization changes."""

    def __init__(
        self,
        repository: ItemRepositoryPort,
        *,
        device_id: str,
        clock: Callable[[], datetime] = _utc_now,
        id_factory: Callable[[str], str] = _default_id_factory,
        reminder_coordinator: Optional[ReminderCoordinatorPort] = None,
    ):
        if not device_id.strip():
            raise ValueError("device_id cannot be empty")
        self.repository = repository
        self.device_id = device_id.strip()
        self._clock = clock
        self._id_factory = id_factory
        self._reminder_coordinator = reminder_coordinator

    def ensure_default_collection(
        self, *, collection_id: str, name: str, color: Optional[str]
    ) -> Collection:
        timestamp = self._now()
        with self.repository.transaction() as transaction:
            existing = transaction.get_collection(
                collection_id, include_deleted=True
            )
            if existing is not None:
                if existing.is_deleted:
                    raise InvalidCommandError(
                        "Configured default collection is deleted and must be restored"
                    )
                return existing
            try:
                collection = Collection(
                    id=collection_id,
                    name=name,
                    color=color,
                    created_at=timestamp,
                    updated_at=timestamp,
                )
            except ValueError as error:
                raise InvalidCommandError(str(error)) from error
            transaction.create_collection(collection)
            transaction.create_outbox_entry(
                self._outbox_for(
                    collection,
                    entity_type=SyncEntityType.COLLECTION,
                    operation=ChangeOperation.CREATE,
                    timestamp=timestamp,
                )
            )
            return collection

    def create_item(
        self, command: CreateItemCommand, *, idempotency_key: str
    ) -> Item:
        self._require_idempotency_key(idempotency_key)
        if command.source is not ItemSource.LOCAL:
            raise InvalidCommandError(
                "Formal CRUD can only create local Items; importers use separate paths"
            )
        request_hash = self._request_hash(command)
        scope = "items:create"
        timestamp = self._now()
        item_id = command.id or self._id_factory("item")
        try:
            item = Item(
                id=item_id,
                collection_id=command.collection_id,
                type=command.type,
                title=command.title,
                body=command.body,
                start_at=command.start_at,
                end_at=command.end_at,
                due_at=command.due_at,
                timezone=command.timezone,
                all_day=command.all_day,
                location=command.location,
                status=command.status,
                priority=command.priority,
                recurrence=command.recurrence,
                reminders=self._build_reminders(item_id, command.reminders),
                tags=list(command.tags),
                source=command.source,
                metadata=dict(command.metadata),
                created_at=timestamp,
                updated_at=timestamp,
            )
        except ValueError as error:
            raise InvalidCommandError(str(error)) from error

        with self.repository.transaction() as transaction:
            replay = self._idempotent_replay(
                transaction, scope, idempotency_key, request_hash
            )
            if replay is not None:
                item = replay
            else:
                self._require_writable_collection(transaction, item.collection_id)
                transaction.create_item(item)
                transaction.create_outbox_entry(
                    self._outbox_for(
                        item,
                        entity_type=SyncEntityType.ITEM,
                        operation=ChangeOperation.CREATE,
                        timestamp=timestamp,
                    )
                )
                self._record_idempotency(
                    transaction,
                    scope,
                    idempotency_key,
                    request_hash,
                    item,
                    timestamp,
                )
        self._reconcile_reminders(item)
        return item

    def get_item(self, item_id: str, *, include_deleted: bool = False) -> Item:
        item = self.repository.get_item(item_id, include_deleted=include_deleted)
        if item is None:
            raise ItemNotFoundError(f"Item {item_id!r} was not found")
        return item

    def list_items(
        self,
        *,
        collection_id: Optional[str] = None,
        item_type: Optional[ItemType] = None,
        status: Optional[ItemStatus] = None,
        from_at: Optional[datetime] = None,
        to_at: Optional[datetime] = None,
        include_deleted: bool = False,
        cursor: Optional[str] = None,
        limit: int = 50,
    ) -> ItemPage:
        if type(limit) is not int or limit < 1 or limit > 200:
            raise InvalidCommandError("limit must be between 1 and 200")
        after = self._decode_cursor(cursor) if cursor else None
        try:
            query = ItemQuery(
                collection_id=collection_id,
                item_type=item_type,
                status=status,
                from_at=from_at,
                to_at=to_at,
                after=after,
                include_deleted=include_deleted,
                limit=limit + 1,
            )
        except ValueError as error:
            raise InvalidCommandError(str(error)) from error
        if from_at is not None or to_at is not None:
            base_query = ItemQuery(
                collection_id=collection_id,
                item_type=item_type,
                status=status,
                include_deleted=include_deleted,
                after=None,
                limit=1000,
            )
            base_results = self.repository.list_items(base_query)
            results = []
            for item in base_results:
                if item.recurrence is not None:
                    results.extend(
                        occurrence
                        for occurrence in expand_item(
                            item, from_at=from_at, to_at=to_at
                        )
                        if (from_at is None or (self._schedule_at(occurrence) is not None and self._schedule_at(occurrence) >= from_at))
                        and (to_at is None or (self._schedule_at(occurrence) is not None and self._schedule_at(occurrence) < to_at))
                    )
                else:
                    schedule_at = self._schedule_at(item)
                    if (from_at is None or (schedule_at is not None and schedule_at >= from_at)) and (
                        to_at is None or (schedule_at is not None and schedule_at < to_at)
                    ):
                        results.append(item)
            results.sort(key=lambda value: (self._schedule_at(value) is None, self._schedule_at(value), value.id))
            if after is not None:
                results = [
                    value
                    for value in results
                    if (
                        self._schedule_at(value) is None
                        and after.schedule_at is None
                        and value.id > after.item_id
                    )
                    or (
                        self._schedule_at(value) is not None
                        and after.schedule_at is not None
                        and (
                            self._schedule_at(value) > after.schedule_at
                            or (
                                self._schedule_at(value) == after.schedule_at
                                and value.id > after.item_id
                            )
                        )
                    )
                ]
        else:
            results = self.repository.list_items(query)
        has_more = len(results) > limit
        items = results[:limit]
        next_cursor = self._encode_cursor(items[-1]) if has_more and items else None
        return ItemPage(items=items, next_cursor=next_cursor, has_more=has_more)

    def update_item(self, item_id: str, command: UpdateItemCommand) -> Item:
        if type(command.expected_version) is not int or command.expected_version < 1:
            raise InvalidCommandError("expected_version must be at least 1")
        timestamp = self._now()
        with self.repository.transaction() as transaction:
            current = transaction.get_item(item_id)
            if current is None:
                raise ItemNotFoundError(f"Item {item_id!r} was not found")
            self._require_writable_item(transaction, current)
            if current.version != command.expected_version:
                raise VersionConflictError(
                    "Item",
                    item_id,
                    command.expected_version,
                    current.version,
                )
            updated = self._apply_patch(current, command.values)
            if updated != current:
                if updated.collection_id != current.collection_id:
                    self._require_writable_collection(
                        transaction, updated.collection_id
                    )
                try:
                    updated.record_update(now=timestamp)
                except ValueError as error:
                    raise InvalidCommandError(str(error)) from error
                transaction.update_item(
                    updated, expected_version=command.expected_version
                )
                transaction.create_outbox_entry(
                    self._outbox_for(
                        updated,
                        entity_type=SyncEntityType.ITEM,
                        operation=ChangeOperation.UPDATE,
                        timestamp=timestamp,
                    )
                )
        self._reconcile_reminders(updated)
        return updated

    def delete_item(self, item_id: str, *, expected_version: int) -> Item:
        timestamp = self._now()
        with self.repository.transaction() as transaction:
            current = transaction.get_item(item_id, include_deleted=True)
            if current is None:
                raise ItemNotFoundError(f"Item {item_id!r} was not found")
            if current.is_deleted:
                deleted = current
            else:
                self._require_writable_item(transaction, current)
                deleted = Item.from_json(current.to_json())
                try:
                    deleted.soft_delete(now=timestamp)
                except ValueError as error:
                    raise InvalidCommandError(str(error)) from error
                transaction.update_item(deleted, expected_version=expected_version)
                transaction.create_outbox_entry(
                    self._outbox_for(
                        deleted,
                        entity_type=SyncEntityType.ITEM,
                        operation=ChangeOperation.DELETE,
                        timestamp=timestamp,
                    )
                )
        self._reconcile_reminders(deleted)
        return deleted

    def restore_item(self, item_id: str, *, expected_version: int) -> Item:
        timestamp = self._now()
        with self.repository.transaction() as transaction:
            current = transaction.get_item(item_id, include_deleted=True)
            if current is None:
                raise ItemNotFoundError(f"Item {item_id!r} was not found")
            if not current.is_deleted:
                restored = current
            else:
                self._require_writable_collection(transaction, current.collection_id)
                restored = Item.from_json(current.to_json())
                restored.restore(now=timestamp)
                transaction.update_item(restored, expected_version=expected_version)
                transaction.create_outbox_entry(
                    self._outbox_for(
                        restored,
                        entity_type=SyncEntityType.ITEM,
                        operation=ChangeOperation.UPDATE,
                        timestamp=timestamp,
                    )
                )
        self._reconcile_reminders(restored)
        return restored

    def complete_task(
        self,
        item_id: str,
        *,
        expected_version: int,
        idempotency_key: str,
    ) -> Item:
        self._require_idempotency_key(idempotency_key)
        scope = f"items:{item_id}:complete"
        request_hash = self._request_hash({"expected_version": expected_version})
        timestamp = self._now()
        with self.repository.transaction() as transaction:
            replay = self._idempotent_replay(
                transaction, scope, idempotency_key, request_hash
            )
            if replay is not None:
                completed = replay
            else:
                current = transaction.get_item(item_id)
                if current is None:
                    raise ItemNotFoundError(f"Item {item_id!r} was not found")
                self._require_writable_item(transaction, current)
                if current.type is not ItemType.TASK:
                    raise InvalidCommandError("Only Task Items can be completed")
                if current.status is ItemStatus.DONE:
                    completed = current
                    self._record_idempotency(
                        transaction,
                        scope,
                        idempotency_key,
                        request_hash,
                        completed,
                        timestamp,
                    )
                else:
                    completed = Item.from_json(current.to_json())
                    completed.status = ItemStatus.DONE
                    completed.record_update(now=timestamp)
                    transaction.update_item(
                        completed, expected_version=expected_version
                    )
                    transaction.create_outbox_entry(
                        self._outbox_for(
                            completed,
                            entity_type=SyncEntityType.ITEM,
                            operation=ChangeOperation.UPDATE,
                            timestamp=timestamp,
                        )
                    )
                    self._record_idempotency(
                        transaction,
                        scope,
                        idempotency_key,
                        request_hash,
                        completed,
                        timestamp,
                    )
        self._reconcile_reminders(completed)
        return completed

    def confirm_candidate(
        self,
        *,
        extraction_id: str,
        candidate: CandidateItem,
        edit: CandidateEditCommand,
        idempotency_key: str,
    ) -> Item:
        self._require_idempotency_key(idempotency_key)
        request_hash = self._request_hash(
            {
                "extraction_id": extraction_id,
                "candidate": candidate,
                "edit": edit,
            }
        )
        scope = "candidates:confirm"
        timestamp = self._now()
        with self.repository.transaction() as transaction:
            item = self._confirm_candidate_in_transaction(
                transaction,
                extraction_id=extraction_id,
                candidate=candidate,
                edit=edit,
                idempotency_key=idempotency_key,
                request_hash=request_hash,
                scope=scope,
                timestamp=timestamp,
            )
        self._reconcile_reminders(item)
        return item

    def _confirm_candidate_in_transaction(
        self,
        transaction: Any,
        *,
        extraction_id: str,
        candidate: CandidateItem,
        edit: CandidateEditCommand,
        idempotency_key: str,
        request_hash: str,
        scope: str,
        timestamp: datetime,
    ) -> Item:
        replay = self._idempotent_replay(
            transaction, scope, idempotency_key, request_hash
        )
        if replay is not None:
            return replay

        extraction = transaction.get_candidate_extraction(extraction_id)
        if extraction is None:
            raise ExtractionNotFoundError(
                f"Candidate extraction {extraction_id!r} was not found"
            )
        if extraction.rejected_at is not None:
            raise ExtractionRejectedError(
                f"Candidate extraction {extraction_id!r} was rejected"
            )
        stored_candidate = next(
            (
                value
                for value in extraction.candidates
                if value.temp_id == candidate.temp_id
            ),
            None,
        )
        if stored_candidate is None:
            raise InvalidCommandError(
                f"Candidate {candidate.temp_id!r} is not in the extraction"
            )
        if stored_candidate.to_dict() != candidate.to_dict():
            raise InvalidCommandError(
                "Submitted Candidate differs from the persisted extraction; "
                "put user changes in edit"
            )

        previous = transaction.get_candidate_confirmation(
            extraction_id, candidate.temp_id
        )
        if previous is not None:
            if previous.request_hash != request_hash:
                raise CandidateDecisionConflictError(
                    "Candidate was already confirmed with different edits"
                )
            item = transaction.get_item(previous.item_id, include_deleted=True)
            if item is None:
                raise ItemNotFoundError(
                    "Confirmed Candidate Item is missing from local storage"
                )
            self._record_idempotency(
                transaction,
                scope,
                idempotency_key,
                request_hash,
                item,
                timestamp,
            )
            return item

        self._require_writable_collection(transaction, edit.collection_id)
        item = self._candidate_to_item(
            candidate,
            edit,
            extraction_id=extraction_id,
            timestamp=timestamp,
        )
        transaction.create_item(item)
        transaction.create_outbox_entry(
            self._outbox_for(
                item,
                entity_type=SyncEntityType.ITEM,
                operation=ChangeOperation.CREATE,
                timestamp=timestamp,
            )
        )
        transaction.create_candidate_confirmation(
            CandidateConfirmationRecord(
                extraction_id=extraction_id,
                temp_id=candidate.temp_id,
                item_id=item.id,
                request_hash=request_hash,
                confirmed_at=timestamp,
            )
        )
        self._record_idempotency(
            transaction,
            scope,
            idempotency_key,
            request_hash,
            item,
            timestamp,
        )
        return item

    def _candidate_to_item(
        self,
        candidate: CandidateItem,
        edit: CandidateEditCommand,
        *,
        extraction_id: str,
        timestamp: datetime,
    ) -> Item:
        candidate_fields = {
            "type",
            "title",
            "body",
            "start_at",
            "end_at",
            "due_at",
            "timezone",
            "location",
            "attendees",
            "reminders",
            "priority",
            "recurrence",
        }
        formal_fields = {"all_day", "status", "tags", "metadata"}
        unknown = set(edit.values) - candidate_fields - formal_fields
        if unknown:
            raise InvalidCommandError(
                f"Unsupported Candidate edit fields: {', '.join(sorted(unknown))}"
            )

        candidate_data = candidate.to_dict()
        edited_reminders = None
        for field_name, value in edit.values.items():
            if field_name == "reminders":
                edited_reminders = value
                continue
            if field_name not in candidate_fields:
                continue
            if isinstance(value, Enum):
                value = value.value
            elif isinstance(value, RecurrenceRule):
                value = value.to_dict()
            elif isinstance(value, datetime):
                value = value.isoformat()
            candidate_data[field_name] = value
        try:
            effective = CandidateItem.from_dict(candidate_data)
            item_id = self._id_factory("item")
            item = effective.to_item(
                collection_id=edit.collection_id,
                item_id=item_id,
                source=ItemSource.AI,
                now=timestamp,
            )
            if edited_reminders is not None:
                item.reminders = self._build_reminders(
                    item_id, edited_reminders
                )
            item.all_day = edit.values.get("all_day", item.all_day)
            item.status = ItemStatus(edit.values.get("status", item.status))
            item.tags = list(edit.values.get("tags", item.tags))
            user_metadata = edit.values.get("metadata") or {}
            item.metadata.update(user_metadata)
            item.metadata.update(
                {
                    "candidate_extraction_id": extraction_id,
                    "candidate_confidence": effective.confidence,
                    "candidate_reasoning": effective.reasoning,
                    "candidate_source_text_span": (
                        effective.source_text_span.to_dict()
                        if effective.source_text_span
                        else None
                    ),
                }
            )
            return Item.from_dict(item.to_dict())
        except (TypeError, ValueError) as error:
            raise InvalidCommandError(str(error)) from error

    def _apply_patch(self, current: Item, values: Mapping[str, Any]) -> Item:
        allowed = {
            "collection_id",
            "type",
            "title",
            "body",
            "start_at",
            "end_at",
            "due_at",
            "timezone",
            "all_day",
            "location",
            "status",
            "priority",
            "recurrence",
            "reminders",
            "tags",
            "metadata",
        }
        unknown = set(values) - allowed
        if unknown:
            raise InvalidCommandError(
                f"Unsupported Item patch fields: {', '.join(sorted(unknown))}"
            )
        data = current.to_dict()
        for field_name, value in values.items():
            if field_name == "reminders":
                value = [
                    reminder.to_dict()
                    for reminder in self._build_reminders(current.id, value)
                ]
            elif isinstance(value, Enum):
                value = value.value
            elif isinstance(value, RecurrenceRule):
                value = value.to_dict()
            elif isinstance(value, datetime):
                value = value.isoformat()
            data[field_name] = value
        try:
            return Item.from_dict(data)
        except ValueError as error:
            raise InvalidCommandError(str(error)) from error

    def _build_reminders(
        self, item_id: str, drafts: List[ReminderDraft]
    ) -> List[Reminder]:
        reminders = []
        for draft in drafts:
            if not isinstance(draft, ReminderDraft):
                raise InvalidCommandError("reminders must contain ReminderDraft values")
            try:
                reminders.append(
                    Reminder(
                        id=draft.id or self._id_factory("reminder"),
                        item_id=item_id,
                        mode=draft.mode,
                        minutes_before=draft.minutes_before,
                        remind_at=draft.remind_at,
                        enabled=draft.enabled,
                    )
                )
            except ValueError as error:
                raise InvalidCommandError(str(error)) from error
        return reminders

    def _reconcile_reminders(self, item: Item) -> None:
        if self._reminder_coordinator is None:
            return
        try:
            current = self.repository.get_item(item.id, include_deleted=True)
            if current is not None:
                self._reminder_coordinator.reconcile_item(current)
        except Exception:
            logger.exception(
                "Reminder reconciliation failed after Item %s version %s was saved",
                item.id,
                item.version,
            )

    @staticmethod
    def _require_writable_collection(transaction: Any, collection_id: str) -> None:
        collection = transaction.get_collection(collection_id)
        if collection is None:
            raise CollectionNotFoundError(
                f"Collection {collection_id!r} was not found"
            )
        if collection.readonly:
            raise ReadonlyCollectionError(
                f"Collection {collection_id!r} is readonly"
            )

    def _require_writable_item(self, transaction: Any, item: Item) -> None:
        self._require_writable_collection(transaction, item.collection_id)
        if item.source is ItemSource.ICS:
            raise ReadonlyCollectionError("ICS Items are readonly")

    def _outbox_for(
        self,
        entity: Item | Collection,
        *,
        entity_type: SyncEntityType,
        operation: ChangeOperation,
        timestamp: datetime,
    ) -> OutboxEntry:
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
        canonical = json.dumps(
            ItemService._jsonable(value),
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        return hashlib.sha256(canonical.encode("utf-8")).hexdigest()

    @staticmethod
    def _jsonable(value: Any) -> Any:
        if is_dataclass(value):
            return ItemService._jsonable(asdict(value))
        if isinstance(value, Enum):
            return value.value
        if isinstance(value, datetime):
            if value.tzinfo is None or value.utcoffset() is None:
                return value.isoformat()
            return value.isoformat()
        if isinstance(value, Mapping):
            return {
                str(key): ItemService._jsonable(item)
                for key, item in value.items()
            }
        if isinstance(value, (list, tuple)):
            return [ItemService._jsonable(item) for item in value]
        return value

    @staticmethod
    def _require_idempotency_key(key: str) -> None:
        if not isinstance(key, str) or not key.strip():
            raise InvalidCommandError("Idempotency-Key is required")
        if len(key.strip()) > 200:
            raise InvalidCommandError(
                "Idempotency-Key cannot exceed 200 characters"
            )

    @staticmethod
    def _idempotent_replay(
        transaction: Any, scope: str, key: str, request_hash: str
    ) -> Optional[Item]:
        record = transaction.get_idempotency_record(scope, key.strip())
        if record is None:
            return None
        if record.request_hash != request_hash:
            raise IdempotencyConflictError(
                "Idempotency-Key was already used for a different request"
            )
        try:
            return Item.from_json(record.response_json)
        except ValueError as error:
            raise InvalidCommandError(
                "Stored idempotent response no longer matches the Item schema"
            ) from error

    @staticmethod
    def _record_idempotency(
        transaction: Any,
        scope: str,
        key: str,
        request_hash: str,
        item: Item,
        timestamp: datetime,
    ) -> None:
        transaction.create_idempotency_record(
            IdempotencyRecord(
                scope=scope,
                key=key.strip(),
                request_hash=request_hash,
                response_json=item.to_json(),
                created_at=timestamp,
            )
        )

    @staticmethod
    def _schedule_at(item: Item) -> Optional[datetime]:
        if item.type is ItemType.EVENT:
            return item.start_at
        if item.type is ItemType.TASK:
            return item.due_at
        return item.start_at or item.due_at

    def _encode_cursor(self, item: Item) -> str:
        schedule_at = self._schedule_at(item)
        payload = {
            "v": 1,
            "at": schedule_at.isoformat() if schedule_at else None,
            "id": item.id,
        }
        encoded = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        return base64.urlsafe_b64encode(encoded).decode("ascii").rstrip("=")

    @staticmethod
    def _decode_cursor(cursor: str) -> ItemPosition:
        try:
            padding = "=" * (-len(cursor) % 4)
            data = json.loads(
                base64.urlsafe_b64decode(cursor + padding).decode("utf-8")
            )
            if set(data) != {"v", "at", "id"} or data["v"] != 1:
                raise ValueError
            schedule_at = (
                datetime.fromisoformat(data["at"].replace("Z", "+00:00"))
                if data["at"] is not None
                else None
            )
            return ItemPosition(schedule_at=schedule_at, item_id=data["id"])
        except (
            ValueError,
            TypeError,
            KeyError,
            json.JSONDecodeError,
            binascii.Error,
        ) as error:
            raise InvalidCursorError("cursor is invalid or unsupported") from error

    def _now(self) -> datetime:
        timestamp = self._clock()
        if timestamp.tzinfo is None or timestamp.utcoffset() is None:
            raise ValueError("ItemService clock must return a timezone-aware datetime")
        return timestamp
