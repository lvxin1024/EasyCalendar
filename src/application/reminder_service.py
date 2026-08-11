"""Local reminder calculation, persistence, and platform reconciliation."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Callable, Dict, Optional

from src.domain import Item, ItemStatus, ItemType, Reminder, ReminderMode
from src.storage import (
    ItemPosition,
    ItemQuery,
    ReminderScheduleRecord,
    ReminderScheduleState,
)

from .ports import (
    NotificationRequest,
    NotificationSchedulerPort,
    ReminderRepositoryPort,
)


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


class ReminderService:
    """Treat platform notifications as recoverable derived Item state."""

    def __init__(
        self,
        repository: ReminderRepositoryPort,
        scheduler: NotificationSchedulerPort,
        *,
        enabled: bool = True,
        clock: Callable[[], datetime] = _utc_now,
    ):
        if type(enabled) is not bool:
            raise ValueError("enabled must be a boolean")
        self.repository = repository
        self.scheduler = scheduler
        self.enabled = enabled
        self._clock = clock

    @staticmethod
    def calculate_fire_at(item: Item, reminder: Reminder) -> Optional[datetime]:
        """Resolve a Reminder against the formal Item schedule."""
        if reminder.mode is ReminderMode.ABSOLUTE:
            return reminder.remind_at
        if item.type is ItemType.EVENT:
            anchor = item.start_at
        elif item.type is ItemType.TASK:
            anchor = item.due_at
        else:
            anchor = None
        if anchor is None or reminder.minutes_before is None:
            return None
        return anchor - timedelta(minutes=reminder.minutes_before)

    def reconcile_item(self, item: Item) -> None:
        self._reconcile_item(item, force=False)

    def restore(self) -> None:
        """Re-register every persisted Item reminder after process startup."""
        after: Optional[ItemPosition] = None
        while True:
            items = self.repository.list_items(
                ItemQuery(include_deleted=True, after=after, limit=1000)
            )
            for item in items:
                self._reconcile_item(item, force=True)
            if len(items) < 1000:
                return
            last = items[-1]
            after = ItemPosition(
                schedule_at=self._item_schedule_at(last),
                item_id=last.id,
            )

    def _reconcile_item(self, item: Item, *, force: bool) -> None:
        now = self._now()
        existing = {
            record.reminder_id: record
            for record in self.repository.list_reminder_schedules(item_id=item.id)
        }
        desired = self._desired_fire_times(item, now=now)

        for reminder_id in existing.keys() - desired.keys():
            self._cancel_and_remove(existing[reminder_id], item, now=now)

        reminders = {reminder.id: reminder for reminder in item.reminders}
        for reminder_id, fire_at in desired.items():
            previous = existing.get(reminder_id)
            if (
                not force
                and previous is not None
                and previous.state is ReminderScheduleState.SCHEDULED
                and previous.item_version == item.version
                and previous.fire_at == fire_at
            ):
                continue
            if previous is not None and not self._cancel_existing(
                previous, item, now=now
            ):
                continue
            request = NotificationRequest(
                notification_id=reminder_id,
                reminder_id=reminder_id,
                item_id=item.id,
                item_version=item.version,
                title=item.title,
                body=item.body,
                fire_at=fire_at,
                timezone_name=item.timezone,
            )
            try:
                platform_id = self.scheduler.schedule(request)
                record = ReminderScheduleRecord(
                    reminder_id=reminders[reminder_id].id,
                    item_id=item.id,
                    item_version=item.version,
                    fire_at=fire_at,
                    state=ReminderScheduleState.SCHEDULED,
                    platform_schedule_id=platform_id,
                    last_error=None,
                    updated_at=now,
                )
            except Exception as error:
                record = ReminderScheduleRecord(
                    reminder_id=reminder_id,
                    item_id=item.id,
                    item_version=item.version,
                    fire_at=fire_at,
                    state=ReminderScheduleState.FAILED,
                    platform_schedule_id=None,
                    last_error=self._error_text("schedule", error),
                    updated_at=now,
                )
            self._persist_schedule(record)

    def _desired_fire_times(
        self, item: Item, *, now: datetime
    ) -> Dict[str, datetime]:
        if (
            not self.enabled
            or item.is_deleted
            or item.status in {ItemStatus.DONE, ItemStatus.CANCELLED}
        ):
            return {}
        result: Dict[str, datetime] = {}
        for reminder in item.reminders:
            if not reminder.enabled:
                continue
            fire_at = self.calculate_fire_at(item, reminder)
            if fire_at is not None and fire_at > now:
                result[reminder.id] = fire_at
        return result

    def _cancel_and_remove(
        self,
        record: ReminderScheduleRecord,
        item: Item,
        *,
        now: datetime,
    ) -> None:
        if self._cancel_existing(record, item, now=now):
            self.repository.delete_reminder_schedule(record.reminder_id)

    def _cancel_existing(
        self,
        record: ReminderScheduleRecord,
        item: Item,
        *,
        now: datetime,
    ) -> bool:
        if record.platform_schedule_id is None:
            return True
        try:
            self.scheduler.cancel(record.platform_schedule_id)
            return True
        except Exception as error:
            self.repository.upsert_reminder_schedule(
                ReminderScheduleRecord(
                    reminder_id=record.reminder_id,
                    item_id=item.id,
                    item_version=item.version,
                    fire_at=record.fire_at,
                    state=ReminderScheduleState.FAILED,
                    platform_schedule_id=record.platform_schedule_id,
                    last_error=self._error_text("cancel", error),
                    updated_at=now,
                )
            )
            return False

    def _now(self) -> datetime:
        value = self._clock()
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("ReminderService clock must return an aware datetime")
        return value

    def _persist_schedule(self, record: ReminderScheduleRecord) -> None:
        try:
            self.repository.upsert_reminder_schedule(record)
        except Exception:
            if (
                record.state is ReminderScheduleState.SCHEDULED
                and record.platform_schedule_id is not None
            ):
                try:
                    self.scheduler.cancel(record.platform_schedule_id)
                except Exception:
                    pass
            raise

    @staticmethod
    def _item_schedule_at(item: Item) -> Optional[datetime]:
        if item.type is ItemType.EVENT:
            return item.start_at
        if item.type is ItemType.TASK:
            return item.due_at
        return item.start_at or item.due_at

    @staticmethod
    def _error_text(operation: str, error: Exception) -> str:
        message = str(error).strip() or type(error).__name__
        return f"{operation}: {message}"[:2000]
