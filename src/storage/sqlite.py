"""Transactional SQLite persistence for EasyCalendar domain models."""

from __future__ import annotations

import json
import sqlite3
import threading
from contextlib import contextmanager
from datetime import datetime, timezone
from importlib import resources
from pathlib import Path
from typing import Any, Dict, Iterator, List, Optional

from src.domain import Collection, Item, OutboxEntry, Subscription

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


LATEST_SCHEMA_VERSION = 2
_MIGRATION_PACKAGE = "src.storage.migrations"
_ITEM_SCHEDULE_SQL = """
CASE item_type
    WHEN 'event' THEN start_at
    WHEN 'task' THEN due_at
    ELSE COALESCE(start_at, due_at)
END
""".strip()


def _utc_text(value: datetime) -> str:
    if (
        not isinstance(value, datetime)
        or value.tzinfo is None
        or value.utcoffset() is None
    ):
        raise ValueError("Persisted timestamps must include a timezone")
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _json_text(value: Any) -> str:
    try:
        return json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        )
    except (TypeError, ValueError) as error:
        raise ValueError("Persisted values must be valid JSON") from error


def _read_json(value: str, label: str) -> Any:
    try:
        return json.loads(value)
    except (TypeError, json.JSONDecodeError) as error:
        raise StorageDataError(f"Stored {label} is not valid JSON") from error


def _migration_files() -> List[tuple[int, str, str]]:
    migrations: List[tuple[int, str, str]] = []
    root = resources.files(_MIGRATION_PACKAGE)
    for entry in root.iterdir():
        if not entry.name.endswith(".sql"):
            continue
        prefix, separator, _ = entry.name.partition("_")
        if not separator or not prefix.isdigit():
            raise RepositoryError(f"Invalid migration filename: {entry.name}")
        migrations.append((int(prefix), entry.name, entry.read_text(encoding="utf-8")))
    migrations.sort(key=lambda migration: migration[0])
    expected = list(range(1, len(migrations) + 1))
    actual = [migration[0] for migration in migrations]
    if actual != expected:
        raise RepositoryError(
            f"SQLite migrations must be contiguous from 1; found versions {actual}"
        )
    return migrations


def _apply_migrations(connection: sqlite3.Connection) -> int:
    connection.execute(
        """
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version INTEGER PRIMARY KEY,
            name TEXT NOT NULL UNIQUE,
            applied_at TEXT NOT NULL
        )
        """
    )
    applied_rows = connection.execute(
        "SELECT version, name FROM schema_migrations ORDER BY version"
    ).fetchall()
    applied = {int(row["version"]): str(row["name"]) for row in applied_rows}
    migrations = _migration_files()
    available = {version: name for version, name, _ in migrations}

    for version, name in applied.items():
        if version not in available or available[version] != name:
            raise RepositoryError(
                f"Database migration {version} ({name}) is not supported by this build"
            )

    for version, name, script in migrations:
        if version in applied:
            continue
        escaped_name = name.replace("'", "''")
        try:
            connection.executescript(
                "BEGIN IMMEDIATE;\n"
                f"{script}\n"
                "INSERT INTO schema_migrations(version, name, applied_at) "
                f"VALUES ({version}, '{escaped_name}', "
                "strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));\n"
                "COMMIT;"
            )
        except sqlite3.Error as error:
            if connection.in_transaction:
                connection.rollback()
            raise RepositoryError(
                f"Failed to apply SQLite migration {name}: {error}"
            ) from error

    current = connection.execute(
        "SELECT COALESCE(MAX(version), 0) AS version FROM schema_migrations"
    ).fetchone()["version"]
    if int(current) != LATEST_SCHEMA_VERSION:
        raise RepositoryError(
            f"Expected SQLite schema {LATEST_SCHEMA_VERSION}, found {current}"
        )
    return int(current)


def _current_schema_version(connection: sqlite3.Connection) -> int:
    table = connection.execute(
        """
        SELECT 1 FROM sqlite_master
        WHERE type = 'table' AND name = 'schema_migrations'
        """
    ).fetchone()
    if table is None:
        return 0
    row = connection.execute(
        "SELECT COALESCE(MAX(version), 0) AS version FROM schema_migrations"
    ).fetchone()
    return int(row["version"])


class SQLiteSession:
    """Operations bound to one caller-controlled SQLite transaction."""

    def __init__(self, connection: sqlite3.Connection):
        self.__connection: Optional[sqlite3.Connection] = connection

    @property
    def _connection(self) -> sqlite3.Connection:
        if self.__connection is None:
            raise RepositoryError("SQLite transaction session is closed")
        return self.__connection

    def _close(self) -> None:
        self.__connection = None

    def create_collection(self, collection: Collection) -> Collection:
        self._require_new_entity(collection, "Collection")
        payload = _json_text(self._validated_payload(collection, "Collection"))
        try:
            self._connection.execute(
                """
                INSERT INTO collections(
                    id, name, kind, readonly, updated_at, deleted_at, version,
                    payload_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    collection.id,
                    collection.name,
                    collection.kind.value,
                    int(collection.readonly),
                    _utc_text(collection.updated_at),
                    _utc_text(collection.deleted_at) if collection.deleted_at else None,
                    collection.version,
                    payload,
                ),
            )
        except sqlite3.IntegrityError as error:
            raise EntityAlreadyExistsError(
                f"Collection {collection.id!r} already exists"
            ) from error
        return collection

    def update_collection(
        self, collection: Collection, *, expected_version: int
    ) -> Collection:
        self._require_next_version(collection, expected_version, "Collection")
        payload = self._validated_payload(collection, "Collection")
        cursor = self._connection.execute(
            """
            UPDATE collections
            SET name = ?, kind = ?, readonly = ?, updated_at = ?, deleted_at = ?,
                version = ?, payload_json = ?
            WHERE id = ? AND version = ?
            """,
            (
                collection.name,
                collection.kind.value,
                int(collection.readonly),
                _utc_text(collection.updated_at),
                _utc_text(collection.deleted_at) if collection.deleted_at else None,
                collection.version,
                _json_text(payload),
                collection.id,
                expected_version,
            ),
        )
        self._check_updated(cursor, "Collection", collection.id, expected_version)
        return collection

    def get_collection(
        self, collection_id: str, *, include_deleted: bool = False
    ) -> Optional[Collection]:
        sql = "SELECT * FROM collections WHERE id = ?"
        parameters: List[Any] = [collection_id]
        if not include_deleted:
            sql += " AND deleted_at IS NULL"
        row = self._connection.execute(sql, parameters).fetchone()
        return self._load_model(row, Collection, "collection") if row else None

    def list_collections(self, *, include_deleted: bool = False) -> List[Collection]:
        sql = "SELECT * FROM collections"
        if not include_deleted:
            sql += " WHERE deleted_at IS NULL"
        sql += " ORDER BY name, id"
        return [
            self._load_model(row, Collection, "collection")
            for row in self._connection.execute(sql).fetchall()
        ]

    def create_item(self, item: Item) -> Item:
        self._require_new_entity(item, "Item")
        payload = self._validated_payload(item, "Item")
        payload["reminders"] = []
        try:
            with self._atomic_operation():
                self._connection.execute(
                    """
                    INSERT INTO items(
                        id, collection_id, item_type, status, start_at, due_at,
                        updated_at, deleted_at, version, payload_json
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    self._item_values(item, payload),
                )
                self._replace_reminders(item)
        except sqlite3.IntegrityError as error:
            if "FOREIGN KEY" in str(error).upper():
                raise ConstraintViolationError(
                    f"Item {item.id!r} references a missing collection"
                ) from error
            raise EntityAlreadyExistsError(
                f"Item {item.id!r} or one of its reminders already exists"
            ) from error
        return item

    def update_item(self, item: Item, *, expected_version: int) -> Item:
        self._require_next_version(item, expected_version, "Item")
        payload = self._validated_payload(item, "Item")
        payload["reminders"] = []
        try:
            with self._atomic_operation():
                cursor = self._connection.execute(
                    """
                    UPDATE items
                    SET collection_id = ?, item_type = ?, status = ?, start_at = ?,
                        due_at = ?, updated_at = ?, deleted_at = ?, version = ?,
                        payload_json = ?
                    WHERE id = ? AND version = ?
                    """,
                    self._item_values(item, payload)[1:]
                    + (item.id, expected_version),
                )
                self._check_updated(cursor, "Item", item.id, expected_version)
                self._replace_reminders(item)
        except sqlite3.IntegrityError as error:
            if "FOREIGN KEY" in str(error).upper():
                raise ConstraintViolationError(
                    f"Item {item.id!r} references a missing collection"
                ) from error
            raise EntityAlreadyExistsError(
                f"A reminder ID used by Item {item.id!r} belongs to another item"
            ) from error
        return item

    def get_item(
        self, item_id: str, *, include_deleted: bool = False
    ) -> Optional[Item]:
        sql = "SELECT * FROM items WHERE id = ?"
        parameters: List[Any] = [item_id]
        if not include_deleted:
            sql += " AND deleted_at IS NULL"
        row = self._connection.execute(sql, parameters).fetchone()
        return self._load_item(row) if row else None

    def list_items(self, query: Optional[ItemQuery] = None) -> List[Item]:
        query = query or ItemQuery()
        predicates: List[str] = []
        parameters: List[Any] = []
        if not query.include_deleted:
            predicates.append("deleted_at IS NULL")
        if query.collection_id is not None:
            predicates.append("collection_id = ?")
            parameters.append(query.collection_id)
        if query.item_type is not None:
            predicates.append("item_type = ?")
            parameters.append(query.item_type.value)
        if query.status is not None:
            predicates.append("status = ?")
            parameters.append(query.status.value)
        if query.from_at is not None:
            predicates.append(f"({_ITEM_SCHEDULE_SQL}) >= ?")
            parameters.append(_utc_text(query.from_at))
        if query.to_at is not None:
            predicates.append(f"({_ITEM_SCHEDULE_SQL}) < ?")
            parameters.append(_utc_text(query.to_at))
        if query.after is not None:
            self._append_item_cursor(predicates, parameters, query.after)

        sql = "SELECT * FROM items"
        if predicates:
            sql += " WHERE " + " AND ".join(predicates)
        sql += (
            f" ORDER BY ({_ITEM_SCHEDULE_SQL}) IS NULL, "
            f"({_ITEM_SCHEDULE_SQL}), id LIMIT ?"
        )
        parameters.append(query.limit)
        return [
            self._load_item(row)
            for row in self._connection.execute(sql, parameters).fetchall()
        ]

    def create_subscription(self, subscription: Subscription) -> Subscription:
        self._require_new_entity(subscription, "Subscription")
        payload = self._validated_payload(subscription, "Subscription")
        try:
            self._connection.execute(
                """
                INSERT INTO subscriptions(
                    id, collection_id, subscription_type, enabled, updated_at,
                    deleted_at, version, payload_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                self._subscription_values(subscription, payload),
            )
        except sqlite3.IntegrityError as error:
            if "FOREIGN KEY" in str(error).upper():
                raise ConstraintViolationError(
                    f"Subscription {subscription.id!r} references a missing collection"
                ) from error
            raise EntityAlreadyExistsError(
                f"Subscription {subscription.id!r} already exists"
            ) from error
        return subscription

    def update_subscription(
        self, subscription: Subscription, *, expected_version: int
    ) -> Subscription:
        self._require_next_version(subscription, expected_version, "Subscription")
        payload = self._validated_payload(subscription, "Subscription")
        try:
            cursor = self._connection.execute(
                """
                UPDATE subscriptions
                SET collection_id = ?, subscription_type = ?, enabled = ?,
                    updated_at = ?, deleted_at = ?, version = ?, payload_json = ?
                WHERE id = ? AND version = ?
                """,
                self._subscription_values(subscription, payload)[1:]
                + (subscription.id, expected_version),
            )
        except sqlite3.IntegrityError as error:
            raise ConstraintViolationError(
                f"Subscription {subscription.id!r} references a missing collection"
            ) from error
        self._check_updated(
            cursor, "Subscription", subscription.id, expected_version
        )
        return subscription

    def get_subscription(
        self, subscription_id: str, *, include_deleted: bool = False
    ) -> Optional[Subscription]:
        sql = "SELECT * FROM subscriptions WHERE id = ?"
        parameters: List[Any] = [subscription_id]
        if not include_deleted:
            sql += " AND deleted_at IS NULL"
        row = self._connection.execute(sql, parameters).fetchone()
        return self._load_model(row, Subscription, "subscription") if row else None

    def list_subscriptions(
        self, *, include_deleted: bool = False
    ) -> List[Subscription]:
        sql = "SELECT * FROM subscriptions"
        if not include_deleted:
            sql += " WHERE deleted_at IS NULL"
        sql += " ORDER BY id"
        return [
            self._load_model(row, Subscription, "subscription")
            for row in self._connection.execute(sql).fetchall()
        ]

    def create_outbox_entry(self, entry: OutboxEntry) -> OutboxEntry:
        payload = self._validated_payload(entry, "OutboxEntry")
        change = entry.change
        try:
            self._connection.execute(
                """
                INSERT INTO outbox(
                    change_id, entity_type, entity_id, operation, entity_version,
                    created_at, retry_count, last_error, sent_at, payload_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    change.change_id,
                    change.entity_type.value,
                    change.entity_id,
                    change.operation.value,
                    change.version,
                    _utc_text(entry.created_at),
                    entry.retry_count,
                    entry.last_error,
                    _utc_text(entry.sent_at) if entry.sent_at else None,
                    _json_text(payload),
                ),
            )
        except sqlite3.IntegrityError as error:
            raise EntityAlreadyExistsError(
                f"Outbox change {change.change_id!r} already exists"
            ) from error
        return entry

    def update_outbox_entry(self, entry: OutboxEntry) -> OutboxEntry:
        payload = self._validated_payload(entry, "OutboxEntry")
        row = self._connection.execute(
            "SELECT * FROM outbox WHERE change_id = ?", (entry.change.change_id,)
        ).fetchone()
        if row is None:
            raise EntityNotFoundError(
                f"Outbox change {entry.change.change_id!r} does not exist"
            )
        stored = self._load_model(row, OutboxEntry, "outbox entry")
        if stored.change != entry.change:
            raise ConstraintViolationError(
                "An outbox SyncChange is immutable after it is created"
            )
        cursor = self._connection.execute(
            """
            UPDATE outbox
            SET retry_count = ?, last_error = ?, sent_at = ?, payload_json = ?
            WHERE change_id = ?
            """,
            (
                entry.retry_count,
                entry.last_error,
                _utc_text(entry.sent_at) if entry.sent_at else None,
                _json_text(payload),
                entry.change.change_id,
            ),
        )
        if cursor.rowcount != 1:
            raise RepositoryError("Outbox entry disappeared during its transaction")
        return entry

    def get_outbox_entry(self, change_id: str) -> Optional[OutboxEntry]:
        row = self._connection.execute(
            "SELECT * FROM outbox WHERE change_id = ?", (change_id,)
        ).fetchone()
        return self._load_model(row, OutboxEntry, "outbox entry") if row else None

    def list_pending_outbox(self, *, limit: int = 200) -> List[OutboxEntry]:
        if type(limit) is not int or limit < 1 or limit > 1000:
            raise ValueError("Outbox limit must be between 1 and 1000")
        rows = self._connection.execute(
            """
            SELECT * FROM outbox
            WHERE sent_at IS NULL
            ORDER BY created_at, change_id
            LIMIT ?
            """,
            (limit,),
        ).fetchall()
        return [self._load_model(row, OutboxEntry, "outbox entry") for row in rows]

    def get_sync_state(self, key: str) -> Any:
        normalized = self._state_key(key)
        row = self._connection.execute(
            "SELECT value_json FROM sync_state WHERE key = ?", (normalized,)
        ).fetchone()
        if row is None:
            return None
        return _read_json(row["value_json"], f"sync state {normalized!r}")

    def get_idempotency_record(
        self, scope: str, key: str
    ) -> Optional[IdempotencyRecord]:
        normalized_scope, normalized_key = self._idempotency_identity(scope, key)
        row = self._connection.execute(
            """
            SELECT scope, key, request_hash, response_json, created_at
            FROM idempotency_records
            WHERE scope = ? AND key = ?
            """,
            (normalized_scope, normalized_key),
        ).fetchone()
        if row is None:
            return None
        try:
            created_at = datetime.fromisoformat(
                str(row["created_at"]).replace("Z", "+00:00")
            )
            return IdempotencyRecord(
                scope=row["scope"],
                key=row["key"],
                request_hash=row["request_hash"],
                response_json=row["response_json"],
                created_at=created_at,
            )
        except (TypeError, ValueError) as error:
            raise StorageDataError(
                f"Stored idempotency record {normalized_scope!r}/{normalized_key!r} "
                "is invalid"
            ) from error

    def create_idempotency_record(
        self, record: IdempotencyRecord
    ) -> IdempotencyRecord:
        if not isinstance(record, IdempotencyRecord):
            raise ValueError("record must be an IdempotencyRecord")
        try:
            self._connection.execute(
                """
                INSERT INTO idempotency_records(
                    scope, key, request_hash, response_json, created_at
                ) VALUES (?, ?, ?, ?, ?)
                """,
                (
                    record.scope,
                    record.key,
                    record.request_hash,
                    record.response_json,
                    _utc_text(record.created_at),
                ),
            )
        except sqlite3.IntegrityError as error:
            raise EntityAlreadyExistsError(
                f"Idempotency record {record.scope!r}/{record.key!r} already exists"
            ) from error
        return record

    def set_sync_state(
        self, key: str, value: Any, *, now: Optional[datetime] = None
    ) -> None:
        normalized = self._state_key(key)
        timestamp = now or datetime.now(timezone.utc)
        self._connection.execute(
            """
            INSERT INTO sync_state(key, value_json, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
                value_json = excluded.value_json,
                updated_at = excluded.updated_at
            """,
            (normalized, _json_text(value), _utc_text(timestamp)),
        )

    def get_sync_cursor(self) -> Optional[str]:
        value = self.get_sync_state("remote_cursor")
        if value is not None and not isinstance(value, str):
            raise StorageDataError("Stored remote sync cursor must be a string")
        return value

    def set_sync_cursor(self, cursor: str, *, now: Optional[datetime] = None) -> None:
        if not isinstance(cursor, str) or not cursor.strip():
            raise ValueError("Sync cursor cannot be empty")
        self.set_sync_state("remote_cursor", cursor, now=now)

    def _replace_reminders(self, item: Item) -> None:
        self._connection.execute("DELETE FROM reminders WHERE item_id = ?", (item.id,))
        self._connection.executemany(
            """
            INSERT INTO reminders(
                id, item_id, position, mode, enabled, payload_json
            ) VALUES (?, ?, ?, ?, ?, ?)
            """,
            [
                (
                    reminder.id,
                    reminder.item_id,
                    position,
                    reminder.mode.value,
                    int(reminder.enabled),
                    _json_text(reminder.to_dict()),
                )
                for position, reminder in enumerate(item.reminders)
            ],
        )

    @staticmethod
    def _append_item_cursor(
        predicates: List[str],
        parameters: List[Any],
        position: ItemPosition,
    ) -> None:
        if position.schedule_at is None:
            predicates.append(f"({_ITEM_SCHEDULE_SQL}) IS NULL AND id > ?")
            parameters.append(position.item_id)
            return
        schedule_text = _utc_text(position.schedule_at)
        predicates.append(
            "("
            f"({_ITEM_SCHEDULE_SQL}) IS NULL OR "
            f"({_ITEM_SCHEDULE_SQL}) > ? OR "
            f"(({_ITEM_SCHEDULE_SQL}) = ? AND id > ?)"
            ")"
        )
        parameters.extend((schedule_text, schedule_text, position.item_id))

    @contextmanager
    def _atomic_operation(self) -> Iterator[None]:
        savepoint = "easycalendar_repository_operation"
        self._connection.execute(f"SAVEPOINT {savepoint}")
        try:
            yield
        except BaseException:
            self._connection.execute(f"ROLLBACK TO SAVEPOINT {savepoint}")
            self._connection.execute(f"RELEASE SAVEPOINT {savepoint}")
            raise
        else:
            self._connection.execute(f"RELEASE SAVEPOINT {savepoint}")

    def _load_item(self, row: sqlite3.Row) -> Item:
        data = _read_json(row["payload_json"], f"item {row['id']!r}")
        if not isinstance(data, dict):
            raise StorageDataError(f"Stored item {row['id']!r} must be an object")
        reminder_rows = self._connection.execute(
            """
            SELECT payload_json FROM reminders
            WHERE item_id = ?
            ORDER BY position, id
            """,
            (row["id"],),
        ).fetchall()
        data["reminders"] = [
            _read_json(reminder_row["payload_json"], f"reminder for {row['id']!r}")
            for reminder_row in reminder_rows
        ]
        try:
            item = Item.from_dict(data)
        except ValueError as error:
            raise StorageDataError(
                f"Stored item {row['id']!r} is invalid: {error}"
            ) from error
        self._verify_identity(item, row, "Item")
        return item

    @staticmethod
    def _load_model(row: sqlite3.Row, model: Any, label: str) -> Any:
        data = _read_json(row["payload_json"], label)
        try:
            result = model.from_dict(data)
        except ValueError as error:
            raise StorageDataError(f"Stored {label} is invalid: {error}") from error
        SQLiteSession._verify_identity(result, row, label.title())
        return result

    @staticmethod
    def _verify_identity(model: Any, row: sqlite3.Row, label: str) -> None:
        stored_id = row["id"] if "id" in row.keys() else row["change_id"]
        model_id = getattr(model, "id", None)
        if model_id is None and isinstance(model, OutboxEntry):
            model_id = model.change.change_id
        if model_id != stored_id:
            raise StorageDataError(f"Stored {label} identity does not match its index")
        if (
            "version" in row.keys()
            and getattr(model, "version", None) != row["version"]
        ):
            raise StorageDataError(f"Stored {label} version does not match its index")

    @staticmethod
    def _item_values(item: Item, payload: Dict[str, Any]) -> tuple[Any, ...]:
        return (
            item.id,
            item.collection_id,
            item.type.value,
            item.status.value,
            _utc_text(item.start_at) if item.start_at else None,
            _utc_text(item.due_at) if item.due_at else None,
            _utc_text(item.updated_at),
            _utc_text(item.deleted_at) if item.deleted_at else None,
            item.version,
            _json_text(payload),
        )

    @staticmethod
    def _subscription_values(
        subscription: Subscription, payload: Dict[str, Any]
    ) -> tuple[Any, ...]:
        return (
            subscription.id,
            subscription.collection_id,
            subscription.type.value,
            int(subscription.enabled),
            _utc_text(subscription.updated_at),
            _utc_text(subscription.deleted_at) if subscription.deleted_at else None,
            subscription.version,
            _json_text(payload),
        )

    @staticmethod
    def _validated_payload(model: Any, label: str) -> Dict[str, Any]:
        data = model.to_dict()
        try:
            type(model).from_dict(data)
        except ValueError as error:
            raise ConstraintViolationError(
                f"{label} does not satisfy the domain contract: {error}"
            ) from error
        return data

    @staticmethod
    def _require_new_entity(entity: Any, label: str) -> None:
        if entity.version != 1 or entity.deleted_at is not None:
            raise ConstraintViolationError(
                f"New {label} records must be active and use version 1"
            )

    @staticmethod
    def _require_next_version(entity: Any, expected: int, label: str) -> None:
        if type(expected) is not int or expected < 1:
            raise ValueError("expected_version must be at least 1")
        if entity.version != expected + 1:
            raise ValueError(
                f"{label} version must be exactly expected_version + 1"
            )

    def _check_updated(
        self, cursor: sqlite3.Cursor, label: str, entity_id: str, expected: int
    ) -> None:
        if cursor.rowcount == 1:
            return
        row = self._connection.execute(
            f"SELECT version FROM {label.lower()}s WHERE id = ?", (entity_id,)
        ).fetchone()
        if row is None:
            raise EntityNotFoundError(f"{label} {entity_id!r} does not exist")
        raise VersionConflictError(label, entity_id, expected, int(row["version"]))

    @staticmethod
    def _state_key(key: str) -> str:
        if not isinstance(key, str) or not key.strip():
            raise ValueError("Sync state key cannot be empty")
        return key.strip()

    @staticmethod
    def _idempotency_identity(scope: str, key: str) -> tuple[str, str]:
        if not isinstance(scope, str) or not scope.strip():
            raise ValueError("Idempotency scope cannot be empty")
        if not isinstance(key, str) or not key.strip():
            raise ValueError("Idempotency key cannot be empty")
        if len(key.strip()) > 200:
            raise ValueError("Idempotency key cannot exceed 200 characters")
        return scope.strip(), key.strip()


class SQLiteRepository:
    """Thread-safe facade that gives each write an explicit transaction."""

    def __init__(self, database_path: str | Path, *, auto_migrate: bool = True):
        if type(auto_migrate) is not bool:
            raise ValueError("auto_migrate must be a boolean")
        raw_path = str(database_path)
        self.path: str | Path = (
            raw_path if raw_path == ":memory:" else Path(raw_path).expanduser()
        )
        if isinstance(self.path, Path):
            self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._closed = False
        self._connection = sqlite3.connect(
            str(self.path),
            isolation_level=None,
            check_same_thread=False,
        )
        self._connection.row_factory = sqlite3.Row
        self._connection.execute("PRAGMA foreign_keys = ON")
        self._connection.execute("PRAGMA busy_timeout = 5000")
        if self.path != ":memory:":
            self._connection.execute("PRAGMA journal_mode = WAL")
            self._connection.execute("PRAGMA synchronous = NORMAL")
        try:
            if auto_migrate:
                self.schema_version = _apply_migrations(self._connection)
            else:
                self.schema_version = _current_schema_version(self._connection)
                if self.schema_version != LATEST_SCHEMA_VERSION:
                    raise RepositoryError(
                        "SQLite schema migration is required but "
                        "deployment.auto_migrate is false"
                    )
        except Exception:
            self._connection.close()
            self._closed = True
            raise

    @classmethod
    def from_settings(cls, settings: Any) -> "SQLiteRepository":
        storage = getattr(settings, "storage", settings)
        if getattr(storage, "driver", None) != "sqlite":
            raise ValueError("SQLiteRepository requires storage.driver=sqlite")
        deployment = getattr(settings, "deployment", None)
        auto_migrate = getattr(deployment, "auto_migrate", True)
        return cls(storage.sqlite_path, auto_migrate=auto_migrate)

    @contextmanager
    def transaction(self) -> Iterator[SQLiteSession]:
        with self._lock:
            self._ensure_open()
            if self._connection.in_transaction:
                raise RepositoryError("Nested SQLite transactions are not supported")
            self._connection.execute("BEGIN IMMEDIATE")
            session = SQLiteSession(self._connection)
            try:
                yield session
            except BaseException:
                self._connection.rollback()
                raise
            else:
                try:
                    self._connection.commit()
                except BaseException:
                    self._connection.rollback()
                    raise
            finally:
                session._close()

    def close(self) -> None:
        with self._lock:
            if not self._closed:
                if self._connection.in_transaction:
                    self._connection.rollback()
                self._connection.close()
                self._closed = True

    def __enter__(self) -> "SQLiteRepository":
        self._ensure_open()
        return self

    def __exit__(self, *_: Any) -> None:
        self.close()

    def create_collection(self, collection: Collection) -> Collection:
        with self.transaction() as session:
            return session.create_collection(collection)

    def update_collection(
        self, collection: Collection, *, expected_version: int
    ) -> Collection:
        with self.transaction() as session:
            return session.update_collection(
                collection, expected_version=expected_version
            )

    def get_collection(
        self, collection_id: str, *, include_deleted: bool = False
    ) -> Optional[Collection]:
        with self._read_session() as session:
            return session.get_collection(
                collection_id, include_deleted=include_deleted
            )

    def list_collections(self, *, include_deleted: bool = False) -> List[Collection]:
        with self._read_session() as session:
            return session.list_collections(include_deleted=include_deleted)

    def create_item(self, item: Item) -> Item:
        with self.transaction() as session:
            return session.create_item(item)

    def update_item(self, item: Item, *, expected_version: int) -> Item:
        with self.transaction() as session:
            return session.update_item(item, expected_version=expected_version)

    def get_item(
        self, item_id: str, *, include_deleted: bool = False
    ) -> Optional[Item]:
        with self._read_session() as session:
            return session.get_item(item_id, include_deleted=include_deleted)

    def list_items(self, query: Optional[ItemQuery] = None) -> List[Item]:
        with self._read_session() as session:
            return session.list_items(query)

    def create_subscription(self, subscription: Subscription) -> Subscription:
        with self.transaction() as session:
            return session.create_subscription(subscription)

    def update_subscription(
        self, subscription: Subscription, *, expected_version: int
    ) -> Subscription:
        with self.transaction() as session:
            return session.update_subscription(
                subscription, expected_version=expected_version
            )

    def get_subscription(
        self, subscription_id: str, *, include_deleted: bool = False
    ) -> Optional[Subscription]:
        with self._read_session() as session:
            return session.get_subscription(
                subscription_id, include_deleted=include_deleted
            )

    def list_subscriptions(
        self, *, include_deleted: bool = False
    ) -> List[Subscription]:
        with self._read_session() as session:
            return session.list_subscriptions(include_deleted=include_deleted)

    def create_outbox_entry(self, entry: OutboxEntry) -> OutboxEntry:
        with self.transaction() as session:
            return session.create_outbox_entry(entry)

    def update_outbox_entry(self, entry: OutboxEntry) -> OutboxEntry:
        with self.transaction() as session:
            return session.update_outbox_entry(entry)

    def get_outbox_entry(self, change_id: str) -> Optional[OutboxEntry]:
        with self._read_session() as session:
            return session.get_outbox_entry(change_id)

    def list_pending_outbox(self, *, limit: int = 200) -> List[OutboxEntry]:
        with self._read_session() as session:
            return session.list_pending_outbox(limit=limit)

    def get_sync_state(self, key: str) -> Any:
        with self._read_session() as session:
            return session.get_sync_state(key)

    def get_idempotency_record(
        self, scope: str, key: str
    ) -> Optional[IdempotencyRecord]:
        with self._read_session() as session:
            return session.get_idempotency_record(scope, key)

    def create_idempotency_record(
        self, record: IdempotencyRecord
    ) -> IdempotencyRecord:
        with self.transaction() as session:
            return session.create_idempotency_record(record)

    def set_sync_state(
        self, key: str, value: Any, *, now: Optional[datetime] = None
    ) -> None:
        with self.transaction() as session:
            session.set_sync_state(key, value, now=now)

    def get_sync_cursor(self) -> Optional[str]:
        with self._read_session() as session:
            return session.get_sync_cursor()

    def set_sync_cursor(self, cursor: str, *, now: Optional[datetime] = None) -> None:
        with self.transaction() as session:
            session.set_sync_cursor(cursor, now=now)

    @contextmanager
    def _read_session(self) -> Iterator[SQLiteSession]:
        with self._lock:
            self._ensure_open()
            yield SQLiteSession(self._connection)

    def _ensure_open(self) -> None:
        if self._closed:
            raise RepositoryError("SQLite repository is closed")
