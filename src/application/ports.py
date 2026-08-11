"""Structural ports consumed by application services."""

from __future__ import annotations

from contextlib import AbstractContextManager
from dataclasses import dataclass
from datetime import datetime
from typing import Optional, Protocol

from src.domain import Collection, Item, OutboxEntry
from src.storage.repository import (
    CandidateConfirmationRecord,
    CandidateExtractionRecord,
    IdempotencyRecord,
    ItemQuery,
    ReminderScheduleRecord,
)


@dataclass(frozen=True)
class NotificationRequest:
    """Platform-neutral notification payload with a stable identity."""

    notification_id: str
    reminder_id: str
    item_id: str
    item_version: int
    title: str
    body: Optional[str]
    fire_at: datetime
    timezone_name: Optional[str]


class ItemTransactionPort(Protocol):
    def get_collection(
        self, collection_id: str, *, include_deleted: bool = False
    ) -> Optional[Collection]: ...

    def create_collection(self, collection: Collection) -> Collection: ...

    def get_item(
        self, item_id: str, *, include_deleted: bool = False
    ) -> Optional[Item]: ...

    def create_item(self, item: Item) -> Item: ...

    def update_item(self, item: Item, *, expected_version: int) -> Item: ...

    def create_outbox_entry(self, entry: OutboxEntry) -> OutboxEntry: ...

    def get_idempotency_record(
        self, scope: str, key: str
    ) -> Optional[IdempotencyRecord]: ...

    def create_idempotency_record(
        self, record: IdempotencyRecord
    ) -> IdempotencyRecord: ...

    def get_candidate_extraction(
        self, extraction_id: str
    ) -> Optional[CandidateExtractionRecord]: ...

    def get_candidate_confirmation(
        self, extraction_id: str, temp_id: str
    ) -> Optional[CandidateConfirmationRecord]: ...

    def create_candidate_confirmation(
        self, record: CandidateConfirmationRecord
    ) -> CandidateConfirmationRecord: ...


class ItemRepositoryPort(Protocol):
    def transaction(self) -> AbstractContextManager[ItemTransactionPort]: ...

    def get_item(
        self, item_id: str, *, include_deleted: bool = False
    ) -> Optional[Item]: ...

    def list_items(self, query: Optional[ItemQuery] = None) -> list[Item]: ...


class CandidateRepositoryPort(ItemRepositoryPort, Protocol):
    def create_candidate_extraction(
        self, record: CandidateExtractionRecord
    ) -> CandidateExtractionRecord: ...

    def get_candidate_extraction(
        self, extraction_id: str
    ) -> Optional[CandidateExtractionRecord]: ...

    def reject_candidate_extraction(
        self,
        extraction_id: str,
        *,
        rejected_at: datetime,
        reason: Optional[str] = None,
    ) -> CandidateExtractionRecord: ...


class ReminderRepositoryPort(ItemRepositoryPort, Protocol):
    def get_reminder_schedule(
        self, reminder_id: str
    ) -> Optional[ReminderScheduleRecord]: ...

    def list_reminder_schedules(
        self, *, item_id: Optional[str] = None
    ) -> list[ReminderScheduleRecord]: ...

    def upsert_reminder_schedule(
        self, record: ReminderScheduleRecord
    ) -> ReminderScheduleRecord: ...

    def delete_reminder_schedule(self, reminder_id: str) -> bool: ...


class NotificationSchedulerPort(Protocol):
    """Adapter boundary implemented by each target notification platform."""

    def schedule(self, request: NotificationRequest) -> str: ...

    def cancel(self, platform_schedule_id: str) -> None: ...


class ReminderCoordinatorPort(Protocol):
    def reconcile_item(self, item: Item) -> None: ...
