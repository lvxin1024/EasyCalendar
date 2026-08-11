"""Tests for recoverable local reminder scheduling."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from config.loader import Settings
from src.application import (
    CreateItemCommand,
    ItemService,
    NotificationRequest,
    ReminderDraft,
    ReminderService,
    UpdateItemCommand,
)
from src.domain import (
    Item,
    ItemStatus,
    ItemType,
    Reminder,
    ReminderMode,
    SyncEntityType,
)
from src.storage import (
    ReminderScheduleState,
    SQLiteRepository,
)
from src.runtime import RuntimeServices


BASE_TIME = datetime(2026, 8, 11, 8, 0, tzinfo=timezone.utc)


class SequenceIds:
    def __init__(self) -> None:
        self.value = 0

    def __call__(self, prefix: str) -> str:
        self.value += 1
        return f"{prefix}_{self.value:04d}"


class SequenceClock:
    def __init__(self) -> None:
        self.value = BASE_TIME - timedelta(seconds=1)

    def __call__(self) -> datetime:
        self.value += timedelta(seconds=1)
        return self.value


class RecordingScheduler:
    def __init__(self) -> None:
        self.requests: list[NotificationRequest] = []
        self.cancelled: list[str] = []
        self.active: dict[str, NotificationRequest] = {}
        self.fail_schedule = False
        self.fail_cancel = False

    def schedule(self, request: NotificationRequest) -> str:
        if self.fail_schedule:
            raise RuntimeError("platform schedule unavailable")
        platform_id = f"platform:{request.reminder_id}:{len(self.requests) + 1}"
        self.requests.append(request)
        self.active[platform_id] = request
        return platform_id

    def cancel(self, platform_schedule_id: str) -> None:
        if self.fail_cancel:
            raise RuntimeError("platform cancellation unavailable")
        self.cancelled.append(platform_schedule_id)
        self.active.pop(platform_schedule_id, None)


def build_item_service(
    repository: SQLiteRepository,
    scheduler: RecordingScheduler,
):
    reminders = ReminderService(
        repository,
        scheduler,
        clock=lambda: BASE_TIME,
    )
    items = ItemService(
        repository,
        device_id="reminder-test",
        clock=SequenceClock(),
        id_factory=SequenceIds(),
        reminder_coordinator=reminders,
    )
    items.ensure_default_collection(
        collection_id="collection_local",
        name="我的日程",
        color="#2563EB",
    )
    return items, reminders


def task_command(**overrides) -> CreateItemCommand:
    values = {
        "collection_id": "collection_local",
        "type": ItemType.TASK,
        "title": "提交报告",
        "due_at": datetime(2026, 8, 12, 18, 0, tzinfo=timezone.utc),
        "timezone": "UTC",
        "reminders": [
            ReminderDraft(
                id="reminder_due",
                mode=ReminderMode.RELATIVE,
                minutes_before=30,
            )
        ],
    }
    values.update(overrides)
    return CreateItemCommand(**values)


def test_calculates_relative_and_absolute_fire_times_with_timezone():
    event_start = datetime.fromisoformat("2026-08-12T10:00:00+08:00")
    event = Item(
        id="item_event",
        collection_id="collection_local",
        type=ItemType.EVENT,
        title="项目同步",
        start_at=event_start,
        timezone="Asia/Shanghai",
        created_at=BASE_TIME,
        updated_at=BASE_TIME,
    )
    relative = Reminder(
        id="reminder_relative",
        item_id=event.id,
        mode=ReminderMode.RELATIVE,
        minutes_before=45,
    )
    absolute_time = datetime.fromisoformat("2026-08-12T08:30:00+08:00")
    absolute = Reminder(
        id="reminder_absolute",
        item_id=event.id,
        mode=ReminderMode.ABSOLUTE,
        remind_at=absolute_time,
    )

    relative_time = ReminderService.calculate_fire_at(event, relative)
    assert relative_time.isoformat() == "2026-08-12T09:15:00+08:00"
    assert ReminderService.calculate_fire_at(event, absolute) == absolute_time

    note = Item(
        id="item_note",
        collection_id="collection_local",
        type=ItemType.NOTE,
        title="无时间笔记",
        timezone="UTC",
        created_at=BASE_TIME,
        updated_at=BASE_TIME,
    )
    note_reminder = Reminder(
        id="reminder_note",
        item_id=note.id,
        mode=ReminderMode.RELATIVE,
        minutes_before=5,
    )
    assert ReminderService.calculate_fire_at(note, note_reminder) is None


def test_item_changes_reschedule_disable_and_cancel_reminders(tmp_path):
    repository = SQLiteRepository(tmp_path / "reminders.sqlite3")
    scheduler = RecordingScheduler()
    items, _ = build_item_service(repository, scheduler)

    created = items.create_item(task_command(), idempotency_key="create-task")
    first = repository.get_reminder_schedule("reminder_due")
    assert first is not None
    assert first.state is ReminderScheduleState.SCHEDULED
    assert first.fire_at == datetime(2026, 8, 12, 17, 30, tzinfo=timezone.utc)
    assert scheduler.requests[-1].item_version == 1
    assert items.create_item(
        task_command(), idempotency_key="create-task"
    ) == created
    assert len(scheduler.requests) == 1

    updated = items.update_item(
        created.id,
        UpdateItemCommand(
            expected_version=1,
            values={
                "due_at": datetime(2026, 8, 13, 12, 0, tzinfo=timezone.utc)
            },
        ),
    )
    second = repository.get_reminder_schedule("reminder_due")
    assert second is not None
    assert second.fire_at == datetime(2026, 8, 13, 11, 30, tzinfo=timezone.utc)
    assert first.platform_schedule_id in scheduler.cancelled
    assert second.platform_schedule_id != first.platform_schedule_id
    assert items.create_item(
        task_command(), idempotency_key="create-task"
    ) == created
    assert repository.get_reminder_schedule("reminder_due") == second
    assert len(scheduler.requests) == 2

    disabled = items.update_item(
        updated.id,
        UpdateItemCommand(
            expected_version=2,
            values={
                "reminders": [
                    ReminderDraft(
                        id="reminder_due",
                        mode=ReminderMode.RELATIVE,
                        minutes_before=30,
                        enabled=False,
                    )
                ]
            },
        ),
    )
    assert repository.get_reminder_schedule("reminder_due") is None
    assert second.platform_schedule_id in scheduler.cancelled

    enabled = items.update_item(
        disabled.id,
        UpdateItemCommand(
            expected_version=3,
            values={
                "reminders": [
                    ReminderDraft(
                        id="reminder_due",
                        mode=ReminderMode.RELATIVE,
                        minutes_before=30,
                        enabled=True,
                    )
                ]
            },
        ),
    )
    active = repository.get_reminder_schedule("reminder_due")
    assert active is not None

    completed = items.complete_task(
        enabled.id,
        expected_version=4,
        idempotency_key="complete-task",
    )
    assert completed.status is ItemStatus.DONE
    assert repository.get_reminder_schedule("reminder_due") is None
    assert active.platform_schedule_id in scheduler.cancelled
    repository.close()


def test_schedule_failure_is_persisted_without_rolling_back_item(tmp_path):
    database_path = tmp_path / "reminders.sqlite3"
    repository = SQLiteRepository(database_path)
    scheduler = RecordingScheduler()
    scheduler.fail_schedule = True
    items, _ = build_item_service(repository, scheduler)

    created = items.create_item(task_command(), idempotency_key="create-task")

    assert repository.get_item(created.id) == created
    item_changes = [
        entry
        for entry in repository.list_pending_outbox()
        if entry.change.entity_type is SyncEntityType.ITEM
    ]
    assert len(item_changes) == 1
    failed = repository.get_reminder_schedule("reminder_due")
    assert failed is not None
    assert failed.state is ReminderScheduleState.FAILED
    assert failed.platform_schedule_id is None
    assert failed.last_error == "schedule: platform schedule unavailable"
    repository.close()

    reopened = SQLiteRepository(database_path)
    recovered_scheduler = RecordingScheduler()
    ReminderService(
        reopened,
        recovered_scheduler,
        clock=lambda: BASE_TIME,
    ).restore()

    recovered = reopened.get_reminder_schedule("reminder_due")
    assert recovered is not None
    assert recovered.state is ReminderScheduleState.SCHEDULED
    assert recovered.last_error is None
    assert len(recovered_scheduler.active) == 1
    assert reopened.get_item(created.id) == created
    reopened.close()


def test_cancel_failure_does_not_block_item_update_and_can_retry(tmp_path):
    repository = SQLiteRepository(tmp_path / "reminders.sqlite3")
    scheduler = RecordingScheduler()
    items, reminders = build_item_service(repository, scheduler)
    created = items.create_item(task_command(), idempotency_key="create-task")
    first = repository.get_reminder_schedule("reminder_due")
    assert first is not None

    scheduler.fail_cancel = True
    updated = items.update_item(
        created.id,
        UpdateItemCommand(
            expected_version=1,
            values={
                "due_at": datetime(2026, 8, 14, 9, 0, tzinfo=timezone.utc)
            },
        ),
    )

    assert repository.get_item(updated.id) == updated
    failed = repository.get_reminder_schedule("reminder_due")
    assert failed is not None
    assert failed.state is ReminderScheduleState.FAILED
    assert failed.platform_schedule_id == first.platform_schedule_id
    assert failed.last_error == "cancel: platform cancellation unavailable"

    scheduler.fail_cancel = False
    reminders.reconcile_item(updated)
    recovered = repository.get_reminder_schedule("reminder_due")
    assert recovered is not None
    assert recovered.state is ReminderScheduleState.SCHEDULED
    assert recovered.fire_at == datetime(2026, 8, 14, 8, 30, tzinfo=timezone.utc)
    assert first.platform_schedule_id in scheduler.cancelled
    repository.close()


def test_global_disable_cancels_existing_platform_schedules(tmp_path):
    repository = SQLiteRepository(tmp_path / "reminders.sqlite3")
    scheduler = RecordingScheduler()
    items, _ = build_item_service(repository, scheduler)
    created = items.create_item(task_command(), idempotency_key="create-task")
    scheduled = repository.get_reminder_schedule("reminder_due")
    assert scheduled is not None

    ReminderService(
        repository,
        scheduler,
        enabled=False,
        clock=lambda: BASE_TIME,
    ).reconcile_item(created)

    assert repository.get_reminder_schedule("reminder_due") is None
    assert scheduled.platform_schedule_id in scheduler.cancelled
    repository.close()


def test_runtime_restores_schedules_from_config_after_restart(tmp_path):
    settings = Settings.model_validate(
        {
            "storage": {"sqlite_path": str(tmp_path / "runtime.sqlite3")},
            "notifications": {
                "enabled": True,
                "adapter": "memory",
                "restore_on_start": True,
            },
        }
    )
    first_scheduler = RecordingScheduler()
    first_runtime = RuntimeServices(
        settings,
        notification_scheduler=first_scheduler,
    )
    created = first_runtime.item_service().create_item(
        task_command(), idempotency_key="runtime-create"
    )
    assert len(first_scheduler.active) == 1
    first_runtime.close()

    restarted_scheduler = RecordingScheduler()
    restarted_runtime = RuntimeServices(
        settings,
        notification_scheduler=restarted_scheduler,
    )
    assert restarted_runtime.item_service().get_item(created.id) == created
    assert len(restarted_scheduler.active) == 1
    restored = next(iter(restarted_scheduler.active.values()))
    assert restored.reminder_id == "reminder_due"
    assert restored.fire_at == datetime(
        2026, 8, 12, 17, 30, tzinfo=timezone.utc
    )
    restarted_runtime.close()
