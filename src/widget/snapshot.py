"""Build and atomically publish the local Widget snapshot."""

from __future__ import annotations

import json
import os
import tempfile
from dataclasses import dataclass
from datetime import datetime, time, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Iterable, Optional, Protocol
from zoneinfo import ZoneInfo

from src.domain import Item, ItemStatus, ItemType, expand_item
from src.storage import ItemQuery


WIDGET_SNAPSHOT_SCHEMA_VERSION = 1
DEFAULT_UPCOMING_DAYS = 7
DEFAULT_ITEM_LIMIT = 20


def _iso(value: Optional[datetime]) -> Optional[str]:
    return value.isoformat() if value is not None else None


def _schedule_at(item: Item) -> Optional[datetime]:
    if item.type is ItemType.EVENT:
        return item.start_at
    if item.type is ItemType.TASK:
        return item.due_at
    return item.start_at or item.due_at


@dataclass(frozen=True)
class WidgetItem:
    """The intentionally small, read-only item representation for widgets."""

    id: str
    type: str
    title: str
    start_at: Optional[str]
    end_at: Optional[str]
    due_at: Optional[str]
    timezone: Optional[str]
    all_day: bool
    location: Optional[str]
    status: str
    priority: Optional[int]
    version: int

    @classmethod
    def from_item(cls, item: Item) -> "WidgetItem":
        return cls(
            id=item.id,
            type=item.type.value,
            title=item.title,
            start_at=_iso(item.start_at),
            end_at=_iso(item.end_at),
            due_at=_iso(item.due_at),
            timezone=item.timezone,
            all_day=item.all_day,
            location=item.location,
            status=item.status.value,
            priority=item.priority,
            version=item.version,
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "type": self.type,
            "title": self.title,
            "start_at": self.start_at,
            "end_at": self.end_at,
            "due_at": self.due_at,
            "timezone": self.timezone,
            "all_day": self.all_day,
            "location": self.location,
            "status": self.status,
            "priority": self.priority,
            "version": self.version,
        }


@dataclass(frozen=True)
class WidgetSnapshot:
    """A complete replacement payload consumed by a platform widget."""

    generated_at: datetime
    timezone: str
    version: int
    today_events: tuple[WidgetItem, ...] = ()
    upcoming_events: tuple[WidgetItem, ...] = ()
    due_items: tuple[WidgetItem, ...] = ()

    def __post_init__(self) -> None:
        if self.generated_at.tzinfo is None or self.generated_at.utcoffset() is None:
            raise ValueError("WidgetSnapshot generated_at must include a timezone")
        if not self.timezone.strip():
            raise ValueError("WidgetSnapshot timezone cannot be empty")
        if type(self.version) is not int or self.version < 0:
            raise ValueError("WidgetSnapshot version cannot be negative")

    @property
    def items(self) -> tuple[WidgetItem, ...]:
        """Return the canonical flattened view for generic widget consumers."""
        return self.today_events + self.upcoming_events + self.due_items

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema_version": WIDGET_SNAPSHOT_SCHEMA_VERSION,
            "generated_at": self.generated_at.isoformat(),
            "timezone": self.timezone,
            "version": self.version,
            "today_events": [item.to_dict() for item in self.today_events],
            "upcoming_events": [item.to_dict() for item in self.upcoming_events],
            "due_items": [item.to_dict() for item in self.due_items],
            "items": [item.to_dict() for item in self.items],
        }


class WidgetSnapshotWriter(Protocol):
    """Port implemented by file or platform-specific snapshot adapters."""

    def write(self, snapshot: WidgetSnapshot) -> None: ...


class FileWidgetSnapshotWriter:
    """Write a complete JSON snapshot with an atomic filesystem replacement."""

    def __init__(self, path: str | Path):
        self.path = Path(path)

    def write(self, snapshot: WidgetSnapshot) -> None:
        payload = json.dumps(
            snapshot.to_dict(),
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        parent = self.path.parent
        parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary = tempfile.mkstemp(
            prefix=f".{self.path.name}.", suffix=".tmp", dir=parent
        )
        try:
            with os.fdopen(descriptor, "wb") as handle:
                descriptor = -1
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, self.path)
            try:
                directory_fd = os.open(parent, os.O_RDONLY)
            except OSError:
                directory_fd = -1
            if directory_fd >= 0:
                try:
                    os.fsync(directory_fd)
                finally:
                    os.close(directory_fd)
        finally:
            if descriptor >= 0:
                os.close(descriptor)
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass


class WidgetSnapshotService:
    """Build snapshots from the canonical Repository and publish them."""

    def __init__(
        self,
        repository: Any,
        writer: WidgetSnapshotWriter,
        *,
        timezone_name: str,
        clock: Callable[[], datetime] = lambda: datetime.now(timezone.utc),
        upcoming_days: int = DEFAULT_UPCOMING_DAYS,
        item_limit: int = DEFAULT_ITEM_LIMIT,
    ):
        if type(upcoming_days) is not int or upcoming_days < 1 or upcoming_days > 31:
            raise ValueError("upcoming_days must be between 1 and 31")
        if type(item_limit) is not int or item_limit < 1 or item_limit > 100:
            raise ValueError("item_limit must be between 1 and 100")
        try:
            self._timezone = ZoneInfo(timezone_name)
        except Exception as error:
            raise ValueError(f"Unknown widget timezone: {timezone_name}") from error
        self.repository = repository
        self.writer = writer
        self._clock = clock
        self.upcoming_days = upcoming_days
        self.item_limit = item_limit

    def refresh(self) -> WidgetSnapshot:
        snapshot = self.build()
        self.writer.write(snapshot)
        return snapshot

    def build(self) -> WidgetSnapshot:
        generated_at = self._clock()
        if generated_at.tzinfo is None or generated_at.utcoffset() is None:
            raise ValueError("Widget clock must return a timezone-aware datetime")
        local_now = generated_at.astimezone(self._timezone)
        today = local_now.date()
        today_start = datetime.combine(today, time.min, tzinfo=self._timezone)
        tomorrow = today + timedelta(days=1)
        upcoming_end = datetime.combine(
            today + timedelta(days=self.upcoming_days + 1),
            time.min,
            tzinfo=self._timezone,
        )
        today_end = datetime.combine(tomorrow, time.min, tzinfo=self._timezone)

        raw_items = self.repository.list_items(ItemQuery(include_deleted=False, limit=1000))
        today_events = self._events_in_window(raw_items, today_start, today_end)
        upcoming_events = self._events_in_window(raw_items, today_end, upcoming_end)
        due_items = self._due_items(raw_items, upcoming_end)
        version = max((item.version for item in raw_items), default=0)
        return WidgetSnapshot(
            generated_at=generated_at,
            timezone=self._timezone.key,
            version=version,
            today_events=tuple(WidgetItem.from_item(item) for item in today_events),
            upcoming_events=tuple(WidgetItem.from_item(item) for item in upcoming_events),
            due_items=tuple(WidgetItem.from_item(item) for item in due_items),
        )

    def _events_in_window(
        self, items: Iterable[Item], start: datetime, end: datetime
    ) -> list[Item]:
        occurrences: list[Item] = []
        for item in items:
            if item.type is not ItemType.EVENT or item.status is ItemStatus.CANCELLED:
                continue
            if item.recurrence is not None:
                occurrences.extend(expand_item(item, from_at=start, to_at=end))
            elif item.start_at is not None and start <= item.start_at < end:
                occurrences.append(item)
        return self._sorted_limited(occurrences)

    def _due_items(self, items: Iterable[Item], end: datetime) -> list[Item]:
        due = [
            item
            for item in items
            if item.type is ItemType.TASK
            and item.due_at is not None
            and item.status not in {ItemStatus.DONE, ItemStatus.CANCELLED}
            and item.due_at < end
        ]
        return self._sorted_limited(due)

    def _sorted_limited(self, items: Iterable[Item]) -> list[Item]:
        return sorted(
            items,
            key=lambda item: (
                _schedule_at(item) is None,
                _schedule_at(item) or datetime.max.replace(tzinfo=timezone.utc),
                item.id,
            ),
        )[: self.item_limit]
