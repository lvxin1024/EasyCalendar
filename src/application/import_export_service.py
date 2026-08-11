"""Transactional JSON backups and iCalendar Event transfers."""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field
from datetime import date, datetime, time, timezone
from typing import Any, Iterable, Literal, Optional
from uuid import uuid4
from zoneinfo import ZoneInfo

from icalendar import Calendar, Event

from src.domain import (
    ChangeOperation,
    Collection,
    Item,
    ItemSource,
    ItemStatus,
    ItemType,
    OutboxEntry,
    RecurrenceRule,
    SourceRef,
    Subscription,
    SyncChange,
    SyncEntityType,
)
from src.domain.serialization import ensure_json_value
from src.storage.repository import IdempotencyRecord, ItemPosition, ItemQuery

from .errors import IdempotencyConflictError, InvalidCommandError
from .ports import TransferRepositoryPort, TransferTransactionPort


BACKUP_SCHEMA_VERSION = 1
ImportFormat = Literal["json", "ics"]
ImportMode = Literal["preview", "commit"]
ImportStrategy = Literal["merge", "replace"]


@dataclass(frozen=True)
class ImportIssue:
    resource_type: str
    index: int
    message: str
    resource_id: Optional[str] = None
    code: str = "invalid"

    def to_dict(self) -> dict[str, Any]:
        return {
            "resource_type": self.resource_type,
            "index": self.index,
            "id": self.resource_id,
            "code": self.code,
            "message": self.message,
        }


@dataclass
class ImportReport:
    format: ImportFormat
    mode: ImportMode
    strategy: ImportStrategy
    accepted: bool = True
    committed: bool = False
    created: dict[str, int] = field(default_factory=dict)
    skipped: dict[str, int] = field(default_factory=dict)
    conflicts: dict[str, int] = field(default_factory=dict)
    issues: list[ImportIssue] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "format": self.format,
            "mode": self.mode,
            "strategy": self.strategy,
            "accepted": self.accepted,
            "committed": self.committed,
            "created": dict(self.created),
            "skipped": dict(self.skipped),
            "conflicts": dict(self.conflicts),
            "issues": [issue.to_dict() for issue in self.issues],
        }

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> "ImportReport":
        return cls(
            format=value["format"],
            mode=value["mode"],
            strategy=value["strategy"],
            accepted=value["accepted"],
            committed=value["committed"],
            created=dict(value["created"]),
            skipped=dict(value["skipped"]),
            conflicts=dict(value["conflicts"]),
            issues=[
                ImportIssue(
                    resource_type=issue["resource_type"],
                    index=issue["index"],
                    resource_id=issue.get("id"),
                    code=issue["code"],
                    message=issue["message"],
                )
                for issue in value["issues"]
            ],
        )


@dataclass(frozen=True)
class _BackupData:
    collections: list[Collection]
    items: list[Item]
    subscriptions: list[Subscription]
    outbox: list[OutboxEntry]
    sync_state: list[dict[str, Any]]


class ImportExportService:
    """Own transfer validation, duplicate detection, and transaction boundaries."""

    def __init__(
        self,
        repository: TransferRepositoryPort,
        *,
        device_id: str,
        timezone_name: str,
        default_collection_id: str,
        max_import_bytes: int,
    ):
        self.repository = repository
        self.device_id = device_id.strip()
        self.timezone_name = timezone_name
        self.default_collection_id = default_collection_id
        self.max_import_bytes = max_import_bytes
        if not self.device_id:
            raise ValueError("device_id cannot be empty")
        try:
            self._timezone = ZoneInfo(timezone_name)
        except Exception as error:
            raise ValueError(f"Unknown transfer timezone: {timezone_name}") from error

    def export_json(self, *, collection_id: Optional[str] = None) -> str:
        with self.repository.transaction() as transaction:
            collections = transaction.list_collections(include_deleted=True)
            if collection_id is not None:
                collections = [value for value in collections if value.id == collection_id]
                if not collections:
                    raise InvalidCommandError(
                        f"Collection {collection_id!r} was not found"
                    )
            collection_ids = {value.id for value in collections}
            items = [
                item
                for item in self._list_all_items(transaction, include_deleted=True)
                if item.collection_id in collection_ids
            ]
            subscriptions = [
                value
                for value in transaction.list_subscriptions(include_deleted=True)
                if value.collection_id in collection_ids
            ]
            entity_ids = collection_ids | {item.id for item in items} | {
                value.id for value in subscriptions
            }
            outbox = [
                entry
                for entry in transaction.list_outbox_entries()
                if collection_id is None or entry.change.entity_id in entity_ids
            ]
            sync_state = transaction.list_sync_state() if collection_id is None else []

        payload = {
            "schema_version": BACKUP_SCHEMA_VERSION,
            "exported_at": self._iso(datetime.now(timezone.utc)),
            "collections": [value.to_dict() for value in collections],
            "items": [value.to_dict() for value in items],
            "subscriptions": [value.to_dict() for value in subscriptions],
            "outbox": [value.to_dict() for value in outbox],
            "sync_state": [
                {
                    "key": value["key"],
                    "value": value["value"],
                    "updated_at": self._iso(value["updated_at"]),
                }
                for value in sync_state
            ],
        }
        return json.dumps(
            payload,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        )

    def export_ics(self, *, collection_id: Optional[str] = None) -> str:
        calendar = Calendar()
        calendar.add("prodid", "-//EasyCalendar//EN")
        calendar.add("version", "2.0")
        calendar.add("calscale", "GREGORIAN")
        with self.repository.transaction() as transaction:
            if collection_id is not None and transaction.get_collection(
                collection_id, include_deleted=False
            ) is None:
                raise InvalidCommandError(f"Collection {collection_id!r} was not found")
            items = self._list_all_items(
                transaction,
                include_deleted=False,
                collection_id=collection_id,
                item_type=ItemType.EVENT,
            )
        for item in items:
            calendar.add_component(self._item_to_event(item))
        return calendar.to_ical().decode("utf-8")

    def import_content(
        self,
        *,
        format: ImportFormat,
        mode: ImportMode,
        strategy: ImportStrategy,
        content: str,
        collection_id: Optional[str] = None,
        idempotency_key: Optional[str] = None,
    ) -> ImportReport:
        self._validate_request(format, mode, strategy, content, idempotency_key)
        if format == "json":
            return self._import_json(
                content,
                mode=mode,
                strategy=strategy,
                idempotency_key=idempotency_key,
            )
        if strategy == "replace":
            raise InvalidCommandError("ICS import only supports merge strategy")
        return self._import_ics(
            content,
            mode=mode,
            collection_id=collection_id or self.default_collection_id,
            idempotency_key=idempotency_key,
        )

    def _import_json(
        self,
        content: str,
        *,
        mode: ImportMode,
        strategy: ImportStrategy,
        idempotency_key: Optional[str],
    ) -> ImportReport:
        backup, issues = self._parse_backup(content)
        report = ImportReport(
            format="json", mode=mode, strategy=strategy, issues=issues
        )
        if issues or backup is None:
            report.accepted = False
            return report

        request_hash = self._request_hash("json", strategy, content, None)
        with self.repository.transaction() as transaction:
            replay = self._idempotent_replay(
                transaction, idempotency_key, request_hash, mode
            )
            if replay is not None:
                return replay
            if strategy == "replace":
                self._count_backup(report.created, backup)
                if mode == "commit":
                    transaction.clear_user_data()
                    self._restore_backup(transaction, backup)
            else:
                self._merge_backup(transaction, backup, report, mode=mode)

            report.accepted = not report.issues
            if report.accepted and mode == "commit":
                report.committed = True
                self._record_idempotency(
                    transaction,
                    idempotency_key,
                    request_hash,
                    report,
                )
        return report

    def _import_ics(
        self,
        content: str,
        *,
        mode: ImportMode,
        collection_id: str,
        idempotency_key: Optional[str],
    ) -> ImportReport:
        items, issues = self._parse_ics(content, collection_id)
        report = ImportReport(
            format="ics", mode=mode, strategy="merge", issues=issues
        )
        if issues:
            report.accepted = False
            return report

        request_hash = self._request_hash("ics", "merge", content, collection_id)
        with self.repository.transaction() as transaction:
            replay = self._idempotent_replay(
                transaction, idempotency_key, request_hash, mode
            )
            if replay is not None:
                return replay
            collection = transaction.get_collection(
                collection_id, include_deleted=False
            )
            if collection is None:
                raise InvalidCommandError(
                    f"Collection {collection_id!r} was not found"
                )
            if collection.readonly:
                raise InvalidCommandError(
                    f"Collection {collection_id!r} is readonly"
                )

            existing = {
                item.id: item
                for item in self._list_all_items(transaction, include_deleted=True)
            }
            seen: dict[str, Item] = {}
            pending: list[Item] = []
            for index, item in enumerate(items):
                previous = seen.get(item.id) or existing.get(item.id)
                if previous is None:
                    seen[item.id] = item
                    pending.append(item)
                    self._increment(report.created, "items")
                    continue
                if self._ics_hash(previous) == self._ics_hash(item):
                    self._increment(report.skipped, "items")
                    continue
                self._add_issue(
                    report,
                    "items",
                    index,
                    item.id,
                    "An Event with this ICS UID has different content",
                    code="conflict",
                )

            report.accepted = not report.issues
            if report.accepted and mode == "commit":
                for item in pending:
                    transaction.create_item(item)
                    transaction.create_outbox_entry(self._outbox_for(item))
                    self._increment(report.created, "outbox")
                report.committed = True
                self._record_idempotency(
                    transaction,
                    idempotency_key,
                    request_hash,
                    report,
                )
        return report

    def _parse_backup(
        self, content: str
    ) -> tuple[Optional[_BackupData], list[ImportIssue]]:
        try:
            raw = json.loads(content)
        except json.JSONDecodeError as error:
            raise InvalidCommandError(
                f"Import content is not valid JSON: {error.msg}"
            ) from error
        if not isinstance(raw, dict):
            raise InvalidCommandError("JSON backup root must be an object")
        expected = {
            "schema_version",
            "exported_at",
            "collections",
            "items",
            "subscriptions",
            "outbox",
            "sync_state",
        }
        unknown = sorted(set(raw) - expected)
        if unknown:
            raise InvalidCommandError(
                f"Unknown JSON backup fields: {', '.join(unknown)}"
            )
        if raw.get("schema_version") != BACKUP_SCHEMA_VERSION:
            raise InvalidCommandError(
                f"Unsupported backup schema version: {raw.get('schema_version')!r}"
            )
        self._parse_datetime(raw.get("exported_at"), "exported_at")
        for name in ("collections", "items", "subscriptions", "outbox", "sync_state"):
            if not isinstance(raw.get(name), list):
                raise InvalidCommandError(f"JSON backup {name} must be an array")

        issues: list[ImportIssue] = []
        collections = self._parse_models(
            raw["collections"], Collection, "collections", issues
        )
        items = self._parse_models(raw["items"], Item, "items", issues)
        subscriptions = self._parse_models(
            raw["subscriptions"], Subscription, "subscriptions", issues
        )
        outbox = self._parse_models(raw["outbox"], OutboxEntry, "outbox", issues)
        sync_state: list[dict[str, Any]] = []
        for index, value in enumerate(raw["sync_state"]):
            resource_id = value.get("key") if isinstance(value, dict) else None
            try:
                if not isinstance(value, dict) or set(value) != {
                    "key", "value", "updated_at"
                }:
                    raise ValueError(
                        "sync state must contain key, value, and updated_at"
                    )
                if not isinstance(value["key"], str) or not value["key"].strip():
                    raise ValueError("sync state key cannot be empty")
                ensure_json_value(value["value"], "sync state value")
                sync_state.append(
                    {
                        "key": value["key"].strip(),
                        "value": value["value"],
                        "updated_at": self._parse_datetime(
                            value["updated_at"], "sync state updated_at"
                        ),
                    }
                )
            except (InvalidCommandError, ValueError) as error:
                issues.append(
                    ImportIssue("sync_state", index, str(error), resource_id)
                )

        self._validate_backup_links(
            collections, items, subscriptions, outbox, sync_state, issues
        )
        if issues:
            return None, issues
        return _BackupData(collections, items, subscriptions, outbox, sync_state), []

    @staticmethod
    def _parse_models(
        values: list[Any], model: Any, resource_type: str, issues: list[ImportIssue]
    ) -> list[Any]:
        parsed = []
        for index, value in enumerate(values):
            resource_id = value.get("id") if isinstance(value, dict) else None
            if model is OutboxEntry and isinstance(value, dict):
                change = value.get("change")
                resource_id = change.get("change_id") if isinstance(change, dict) else None
            try:
                parsed.append(model.from_dict(value))
            except (TypeError, ValueError) as error:
                issues.append(
                    ImportIssue(resource_type, index, str(error), resource_id)
                )
        return parsed

    @staticmethod
    def _validate_backup_links(
        collections: list[Collection],
        items: list[Item],
        subscriptions: list[Subscription],
        outbox: list[OutboxEntry],
        sync_state: list[dict[str, Any]],
        issues: list[ImportIssue],
    ) -> None:
        def duplicate_issues(resource_type: str, values: Iterable[tuple[str, int]]) -> None:
            seen: set[str] = set()
            for resource_id, index in values:
                if resource_id in seen:
                    issues.append(
                        ImportIssue(
                            resource_type,
                            index,
                            "Duplicate ID in backup",
                            resource_id,
                        )
                    )
                seen.add(resource_id)

        duplicate_issues(
            "collections", ((value.id, i) for i, value in enumerate(collections))
        )
        duplicate_issues("items", ((value.id, i) for i, value in enumerate(items)))
        duplicate_issues(
            "subscriptions", ((value.id, i) for i, value in enumerate(subscriptions))
        )
        duplicate_issues(
            "outbox",
            ((value.change.change_id, i) for i, value in enumerate(outbox)),
        )
        duplicate_issues(
            "sync_state", ((value["key"], i) for i, value in enumerate(sync_state))
        )
        collection_ids = {value.id for value in collections}
        for index, item in enumerate(items):
            if item.collection_id not in collection_ids:
                issues.append(
                    ImportIssue(
                        "items",
                        index,
                        f"Missing Collection {item.collection_id!r}",
                        item.id,
                    )
                )
        for index, subscription in enumerate(subscriptions):
            if subscription.collection_id not in collection_ids:
                issues.append(
                    ImportIssue(
                        "subscriptions",
                        index,
                        f"Missing Collection {subscription.collection_id!r}",
                        subscription.id,
                    )
                )
        entity_ids = {
            SyncEntityType.COLLECTION: collection_ids,
            SyncEntityType.ITEM: {value.id for value in items},
            SyncEntityType.SUBSCRIPTION: {value.id for value in subscriptions},
        }
        for index, entry in enumerate(outbox):
            if entry.change.entity_id not in entity_ids[entry.change.entity_type]:
                issues.append(
                    ImportIssue(
                        "outbox",
                        index,
                        "Outbox change references an entity missing from the backup",
                        entry.change.change_id,
                    )
                )

    def _merge_backup(
        self,
        transaction: TransferTransactionPort,
        backup: _BackupData,
        report: ImportReport,
        *,
        mode: ImportMode,
    ) -> None:
        resources = (
            (
                "collections",
                backup.collections,
                lambda value: transaction.get_collection(value.id, include_deleted=True),
                transaction.restore_collection,
            ),
            (
                "items",
                backup.items,
                lambda value: transaction.get_item(value.id, include_deleted=True),
                transaction.restore_item,
            ),
            (
                "subscriptions",
                backup.subscriptions,
                lambda value: transaction.get_subscription(value.id, include_deleted=True),
                transaction.restore_subscription,
            ),
            (
                "outbox",
                backup.outbox,
                lambda value: transaction.get_outbox_entry(value.change.change_id),
                transaction.create_outbox_entry,
            ),
        )
        pending: list[tuple[Any, Any]] = []
        for resource_type, values, getter, writer in resources:
            for index, value in enumerate(values):
                current = getter(value)
                if current is None:
                    self._increment(report.created, resource_type)
                    pending.append((writer, value))
                elif current.to_dict() == value.to_dict():
                    self._increment(report.skipped, resource_type)
                else:
                    self._add_issue(
                        report,
                        resource_type,
                        index,
                        self._resource_id(value),
                        "An entity with this ID has different content",
                        code="conflict",
                    )

        existing_state = {value["key"]: value for value in transaction.list_sync_state()}
        pending_state: list[dict[str, Any]] = []
        for index, value in enumerate(backup.sync_state):
            current = existing_state.get(value["key"])
            if current is None:
                self._increment(report.created, "sync_state")
                pending_state.append(value)
            elif current == value:
                self._increment(report.skipped, "sync_state")
            else:
                self._add_issue(
                    report,
                    "sync_state",
                    index,
                    value["key"],
                    "A sync state key has different content",
                    code="conflict",
                )

        if report.issues or mode != "commit":
            return
        for writer, value in pending:
            writer(value)
        for value in pending_state:
            transaction.restore_sync_state(
                value["key"], value["value"], updated_at=value["updated_at"]
            )

    @staticmethod
    def _restore_backup(
        transaction: TransferTransactionPort, backup: _BackupData
    ) -> None:
        for value in backup.collections:
            transaction.restore_collection(value)
        for value in backup.items:
            transaction.restore_item(value)
        for value in backup.subscriptions:
            transaction.restore_subscription(value)
        for value in backup.outbox:
            transaction.create_outbox_entry(value)
        for value in backup.sync_state:
            transaction.restore_sync_state(
                value["key"], value["value"], updated_at=value["updated_at"]
            )

    def _parse_ics(
        self, content: str, collection_id: str
    ) -> tuple[list[Item], list[ImportIssue]]:
        try:
            calendar = Calendar.from_ical(content)
        except Exception as error:
            raise InvalidCommandError(f"Import content is not valid ICS: {error}") from error
        items: list[Item] = []
        issues: list[ImportIssue] = []
        components = [value for value in calendar.walk() if value.name == "VEVENT"]
        if not components:
            raise InvalidCommandError("ICS import contains no VEVENT components")
        now = datetime.now(timezone.utc)
        for index, component in enumerate(components):
            uid = self._text_property(component, "UID")
            try:
                item = self._event_to_item(component, collection_id, now=now)
                items.append(item)
            except (TypeError, ValueError, KeyError) as error:
                issues.append(ImportIssue("events", index, str(error), uid))
        return items, issues

    def _event_to_item(
        self, component: Event, collection_id: str, *, now: datetime
    ) -> Item:
        summary = self._text_property(component, "SUMMARY")
        if not summary:
            raise ValueError("VEVENT SUMMARY is required")
        if "DTSTART" not in component:
            raise ValueError("VEVENT DTSTART is required")
        raw_start = component.decoded("DTSTART")
        raw_end = component.decoded("DTEND") if "DTEND" in component else None
        all_day = isinstance(raw_start, date) and not isinstance(raw_start, datetime)
        start_at = self._ical_datetime(raw_start)
        end_at = self._ical_datetime(raw_end) if raw_end is not None else None
        uid = self._text_property(component, "UID")
        recurrence = self._recurrence_from_event(component)
        tags = self._categories(component)
        status = (
            ItemStatus.CANCELLED
            if (self._text_property(component, "STATUS") or "").upper() == "CANCELLED"
            else ItemStatus.TODO
        )
        canonical = {
            "uid": uid,
            "title": summary,
            "body": self._text_property(component, "DESCRIPTION"),
            "location": self._text_property(component, "LOCATION"),
            "start_at": self._iso(start_at),
            "end_at": self._iso(end_at) if end_at else None,
            "all_day": all_day,
            "status": status.value,
            "recurrence": recurrence.to_dict() if recurrence else None,
            "tags": tags,
        }
        content_hash = self._hash_json(canonical)
        external_id = uid or f"generated-{content_hash}"
        item_id = f"item_ics_{hashlib.sha256(external_id.encode('utf-8')).hexdigest()[:24]}"
        return Item(
            id=item_id,
            collection_id=collection_id,
            type=ItemType.EVENT,
            title=summary,
            body=canonical["body"],
            start_at=start_at,
            end_at=end_at,
            timezone=self.timezone_name,
            all_day=all_day,
            location=canonical["location"],
            status=status,
            recurrence=recurrence,
            tags=tags,
            source=ItemSource.ICS,
            source_ref=SourceRef(provider="ics", external_id=external_id),
            metadata={"ics_uid": external_id, "ics_hash": content_hash},
            created_at=now,
            updated_at=now,
        )

    def _item_to_event(self, item: Item) -> Event:
        event = Event()
        uid = (
            item.source_ref.external_id
            if item.source_ref is not None
            and item.source_ref.provider == "ics"
            and item.source_ref.external_id
            else f"{item.id}@easycalendar.local"
        )
        event.add("uid", uid)
        event.add("dtstamp", item.created_at)
        event.add("summary", item.title)
        if item.body:
            event.add("description", item.body)
        if item.location:
            event.add("location", item.location)
        if item.all_day:
            local_start = item.start_at.astimezone(self._timezone).date()
            event.add("dtstart", local_start)
            if item.end_at is not None:
                event.add("dtend", item.end_at.astimezone(self._timezone).date())
        else:
            event.add("dtstart", item.start_at)
            if item.end_at is not None:
                event.add("dtend", item.end_at)
        if item.recurrence is not None:
            event.add("rrule", self._rrule_dict(item.recurrence.rrule))
            for value in item.recurrence.exdates:
                event.add("exdate", self._parse_recurrence_date(value))
            for value in item.recurrence.rdates:
                event.add("rdate", self._parse_recurrence_date(value))
        if item.tags:
            event.add("categories", item.tags)
        event.add(
            "status", "CANCELLED" if item.status is ItemStatus.CANCELLED else "CONFIRMED"
        )
        event.add("last-modified", item.updated_at)
        return event

    def _recurrence_from_event(self, component: Event) -> Optional[RecurrenceRule]:
        if "RRULE" not in component:
            return None
        raw = component["RRULE"].to_ical().decode("utf-8")
        exdates = self._recurrence_values(component, "EXDATE")
        rdates = self._recurrence_values(component, "RDATE")
        return RecurrenceRule(rrule=raw, exdates=exdates, rdates=rdates)

    def _recurrence_values(self, component: Event, name: str) -> list[str]:
        if name not in component:
            return []
        properties = component[name]
        if not isinstance(properties, list):
            properties = [properties]
        result: list[str] = []
        for prop in properties:
            values = getattr(prop, "dts", [])
            for value in values:
                dt = value.dt
                if isinstance(dt, datetime):
                    result.append(self._iso(self._ical_datetime(dt)))
                else:
                    result.append(dt.isoformat())
        return result

    @staticmethod
    def _rrule_dict(value: str) -> dict[str, list[str]]:
        result: dict[str, list[str]] = {}
        for part in value.split(";"):
            key, separator, raw = part.partition("=")
            if not separator or not key or not raw:
                raise InvalidCommandError(f"Invalid recurrence rule: {value}")
            result[key.upper()] = raw.split(",")
        return result

    def _parse_recurrence_date(self, value: str) -> date | datetime:
        if "T" not in value:
            return date.fromisoformat(value)
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return self._ical_datetime(parsed)

    def _ical_datetime(self, value: date | datetime) -> datetime:
        if isinstance(value, datetime):
            if value.tzinfo is None or value.utcoffset() is None:
                return value.replace(tzinfo=self._timezone)
            return value
        if isinstance(value, date):
            return datetime.combine(value, time.min, tzinfo=self._timezone)
        raise ValueError("ICS date value is invalid")

    @staticmethod
    def _text_property(component: Event, name: str) -> Optional[str]:
        value = component.get(name)
        if value is None:
            return None
        text = str(value).strip()
        return text or None

    @staticmethod
    def _categories(component: Event) -> list[str]:
        value = component.get("CATEGORIES")
        if value is None:
            return []
        values = getattr(value, "cats", None)
        if values is None:
            return [part.strip() for part in str(value).split(",") if part.strip()]
        return [str(part).strip() for part in values if str(part).strip()]

    def _outbox_for(self, item: Item) -> OutboxEntry:
        change = SyncChange(
            change_id=f"change_{uuid4().hex}",
            device_id=self.device_id,
            entity_type=SyncEntityType.ITEM,
            entity_id=item.id,
            operation=ChangeOperation.CREATE,
            version=item.version,
            updated_at=item.updated_at,
            payload=item.to_dict(),
        )
        return OutboxEntry(change=change, created_at=item.updated_at)

    @staticmethod
    def _ics_hash(item: Item) -> Optional[str]:
        value = item.metadata.get("ics_hash")
        return value if isinstance(value, str) else None

    @staticmethod
    def _list_all_items(
        transaction: TransferTransactionPort,
        *,
        include_deleted: bool,
        collection_id: Optional[str] = None,
        item_type: Optional[ItemType] = None,
    ) -> list[Item]:
        items: list[Item] = []
        after: Optional[ItemPosition] = None
        while True:
            page = transaction.list_items(
                ItemQuery(
                    collection_id=collection_id,
                    item_type=item_type,
                    include_deleted=include_deleted,
                    after=after,
                    limit=1000,
                )
            )
            items.extend(page)
            if len(page) < 1000:
                return items
            last = page[-1]
            after = ItemPosition(
                schedule_at=last.start_at if last.type is ItemType.EVENT else last.due_at,
                item_id=last.id,
            )

    def _idempotent_replay(
        self,
        transaction: TransferTransactionPort,
        key: Optional[str],
        request_hash: str,
        mode: ImportMode,
    ) -> Optional[ImportReport]:
        if mode != "commit" or key is None:
            return None
        record = transaction.get_idempotency_record("transfer:import", key)
        if record is None:
            return None
        if record.request_hash != request_hash:
            raise IdempotencyConflictError(
                "Idempotency-Key was already used for a different import"
            )
        try:
            return ImportReport.from_dict(json.loads(record.response_json))
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
            raise InvalidCommandError("Stored import replay is invalid") from error

    @staticmethod
    def _record_idempotency(
        transaction: TransferTransactionPort,
        key: Optional[str],
        request_hash: str,
        report: ImportReport,
    ) -> None:
        if key is None:
            raise InvalidCommandError("Idempotency-Key is required for commit mode")
        transaction.create_idempotency_record(
            IdempotencyRecord(
                scope="transfer:import",
                key=key,
                request_hash=request_hash,
                response_json=json.dumps(
                    report.to_dict(),
                    ensure_ascii=False,
                    sort_keys=True,
                    separators=(",", ":"),
                ),
                created_at=datetime.now(timezone.utc),
            )
        )

    def _validate_request(
        self,
        format: str,
        mode: str,
        strategy: str,
        content: str,
        idempotency_key: Optional[str],
    ) -> None:
        if format not in {"json", "ics"}:
            raise InvalidCommandError("format must be json or ics")
        if mode not in {"preview", "commit"}:
            raise InvalidCommandError("mode must be preview or commit")
        if strategy not in {"merge", "replace"}:
            raise InvalidCommandError("strategy must be merge or replace")
        if not isinstance(content, str) or not content.strip():
            raise InvalidCommandError("Import content cannot be empty")
        if len(content.encode("utf-8")) > self.max_import_bytes:
            raise InvalidCommandError(
                f"Import content exceeds {self.max_import_bytes} bytes"
            )
        if mode == "commit" and (not idempotency_key or not idempotency_key.strip()):
            raise InvalidCommandError("Idempotency-Key is required for commit mode")
        if idempotency_key is not None and len(idempotency_key) > 200:
            raise InvalidCommandError("Idempotency-Key cannot exceed 200 characters")

    @staticmethod
    def _parse_datetime(value: Any, label: str) -> datetime:
        if not isinstance(value, str):
            raise InvalidCommandError(f"{label} must be an ISO 8601 string")
        try:
            result = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError as error:
            raise InvalidCommandError(
                f"{label} must be a valid ISO 8601 datetime"
            ) from error
        if result.tzinfo is None or result.utcoffset() is None:
            raise InvalidCommandError(f"{label} must include a timezone")
        return result

    @staticmethod
    def _request_hash(
        format: str, strategy: str, content: str, collection_id: Optional[str]
    ) -> str:
        return ImportExportService._hash_json(
            {
                "format": format,
                "strategy": strategy,
                "content": content,
                "collection_id": collection_id,
            }
        )

    @staticmethod
    def _hash_json(value: Any) -> str:
        encoded = json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        return hashlib.sha256(encoded).hexdigest()

    @staticmethod
    def _iso(value: datetime) -> str:
        text = value.isoformat()
        return text.removesuffix("+00:00") + "Z" if text.endswith("+00:00") else text

    @staticmethod
    def _resource_id(value: Any) -> str:
        if isinstance(value, OutboxEntry):
            return value.change.change_id
        return value.id

    @staticmethod
    def _increment(target: dict[str, int], key: str) -> None:
        target[key] = target.get(key, 0) + 1

    @staticmethod
    def _count_backup(target: dict[str, int], backup: _BackupData) -> None:
        for key, values in (
            ("collections", backup.collections),
            ("items", backup.items),
            ("subscriptions", backup.subscriptions),
            ("outbox", backup.outbox),
            ("sync_state", backup.sync_state),
        ):
            if values:
                target[key] = len(values)

    @staticmethod
    def _add_issue(
        report: ImportReport,
        resource_type: str,
        index: int,
        resource_id: Optional[str],
        message: str,
        *,
        code: str,
    ) -> None:
        report.issues.append(
            ImportIssue(resource_type, index, message, resource_id, code)
        )
        ImportExportService._increment(report.conflicts, resource_type)
