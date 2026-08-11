"""Structural ports consumed by application services."""

from __future__ import annotations

from contextlib import AbstractContextManager
from typing import Optional, Protocol

from src.domain import Collection, Item, OutboxEntry
from src.storage.repository import IdempotencyRecord, ItemQuery


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


class ItemRepositoryPort(Protocol):
    def transaction(self) -> AbstractContextManager[ItemTransactionPort]: ...

    def get_item(
        self, item_id: str, *, include_deleted: bool = False
    ) -> Optional[Item]: ...

    def list_items(self, query: Optional[ItemQuery] = None) -> list[Item]: ...
