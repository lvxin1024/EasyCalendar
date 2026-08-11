"""Application and API tests for formal Item CRUD use cases."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from config.loader import Settings
from src.application import (
    CreateItemCommand,
    IdempotencyConflictError,
    InvalidCommandError,
    InvalidCursorError,
    ItemService,
    ReadonlyCollectionError,
    UpdateItemCommand,
)
from src.domain import (
    ChangeOperation,
    Collection,
    CollectionKind,
    ItemStatus,
    ItemType,
    ReminderMode,
    SyncEntityType,
)
from src.main import create_app
from src.storage import SQLiteRepository, VersionConflictError


BASE_TIME = datetime(2026, 8, 11, 8, 0, tzinfo=timezone.utc)


class SequenceIds:
    def __init__(self):
        self.value = 0

    def __call__(self, prefix: str) -> str:
        self.value += 1
        return f"{prefix}_{self.value:04d}"


class SequenceClock:
    def __init__(self):
        self.value = BASE_TIME - timedelta(seconds=1)

    def __call__(self) -> datetime:
        self.value += timedelta(seconds=1)
        return self.value


@pytest.fixture
def service_bundle(tmp_path):
    database_path = tmp_path / "app.sqlite3"
    repository = SQLiteRepository(database_path)
    service = ItemService(
        repository,
        device_id="test-device",
        clock=SequenceClock(),
        id_factory=SequenceIds(),
    )
    service.ensure_default_collection(
        collection_id="collection_local",
        name="我的日程",
        color="#2563EB",
    )
    yield service, repository, database_path
    repository.close()


def task_command(**overrides) -> CreateItemCommand:
    values = {
        "collection_id": "collection_local",
        "type": ItemType.TASK,
        "title": "提交报告",
        "due_at": datetime(2026, 8, 14, 18, 0, tzinfo=timezone.utc),
        "timezone": "UTC",
        "tags": ["工作"],
    }
    values.update(overrides)
    return CreateItemCommand(**values)


def item_changes(repository):
    return [
        entry.change
        for entry in repository.list_pending_outbox()
        if entry.change.entity_type is SyncEntityType.ITEM
    ]


def test_create_is_atomic_with_outbox_and_idempotent_across_restart(service_bundle):
    service, repository, database_path = service_bundle
    command = task_command()

    created = service.create_item(command, idempotency_key="create-report")
    replayed = service.create_item(command, idempotency_key="create-report")

    assert replayed == created
    assert repository.get_item(created.id) == created
    assert [change.operation for change in item_changes(repository)] == [
        ChangeOperation.CREATE
    ]

    with pytest.raises(IdempotencyConflictError):
        service.create_item(
            task_command(title="另一个标题"),
            idempotency_key="create-report",
        )

    repository.close()
    reopened = SQLiteRepository(database_path)
    restarted_service = ItemService(
        reopened,
        device_id="test-device",
        clock=SequenceClock(),
        id_factory=SequenceIds(),
    )
    try:
        assert (
            restarted_service.create_item(
                command, idempotency_key="create-report"
            )
            == created
        )
        assert len(item_changes(reopened)) == 1
    finally:
        reopened.close()


def test_update_checks_version_and_writes_one_change(service_bundle):
    service, repository, _ = service_bundle
    item = service.create_item(task_command(), idempotency_key="create")

    updated = service.update_item(
        item.id,
        UpdateItemCommand(
            expected_version=1,
            values={"title": "提交最终报告", "priority": 3},
        ),
    )

    assert updated.title == "提交最终报告"
    assert updated.priority == 3
    assert updated.version == 2
    assert [change.operation for change in item_changes(repository)] == [
        ChangeOperation.CREATE,
        ChangeOperation.UPDATE,
    ]

    with pytest.raises(VersionConflictError):
        service.update_item(
            item.id,
            UpdateItemCommand(expected_version=1, values={"title": "过期更新"}),
        )


def test_delete_is_idempotent_and_restore_creates_update_change(service_bundle):
    service, repository, _ = service_bundle
    item = service.create_item(task_command(), idempotency_key="create")

    deleted = service.delete_item(item.id, expected_version=1)
    repeated = service.delete_item(item.id, expected_version=999)

    assert deleted.is_deleted
    assert repeated == deleted
    assert repository.get_item(item.id) is None
    assert len(item_changes(repository)) == 2

    restored = service.restore_item(item.id, expected_version=2)
    assert restored.deleted_at is None
    assert restored.version == 3
    assert repository.get_item(item.id) == restored
    assert [change.operation for change in item_changes(repository)] == [
        ChangeOperation.CREATE,
        ChangeOperation.DELETE,
        ChangeOperation.UPDATE,
    ]


def test_complete_task_is_idempotent_and_rejects_events(service_bundle):
    service, repository, _ = service_bundle
    task = service.create_item(task_command(), idempotency_key="create-task")

    completed = service.complete_task(
        task.id,
        expected_version=1,
        idempotency_key="complete-task",
    )
    replayed = service.complete_task(
        task.id,
        expected_version=1,
        idempotency_key="complete-task",
    )
    repeated = service.complete_task(
        task.id,
        expected_version=1,
        idempotency_key="complete-task-again",
    )

    assert completed.status is ItemStatus.DONE
    assert completed.version == 2
    assert replayed == completed
    assert repeated == completed
    assert len(item_changes(repository)) == 2

    event = service.create_item(
        CreateItemCommand(
            collection_id="collection_local",
            type=ItemType.EVENT,
            title="项目同步",
            start_at=datetime(2026, 8, 12, 10, 0, tzinfo=timezone.utc),
            timezone="UTC",
        ),
        idempotency_key="create-event",
    )
    with pytest.raises(InvalidCommandError, match="Only Task"):
        service.complete_task(
            event.id,
            expected_version=1,
            idempotency_key="complete-event",
        )


def test_readonly_collection_rejects_formal_crud(service_bundle):
    service, repository, _ = service_bundle
    repository.create_collection(
        Collection(
            id="collection_subscription",
            name="课程表",
            kind=CollectionKind.SUBSCRIPTION,
            readonly=True,
            created_at=BASE_TIME,
            updated_at=BASE_TIME,
        )
    )

    with pytest.raises(ReadonlyCollectionError):
        service.create_item(
            task_command(collection_id="collection_subscription"),
            idempotency_key="readonly-create",
        )

    assert item_changes(repository) == []


def test_cursor_pagination_is_stable_for_dated_and_undated_items(service_bundle):
    service, _, _ = service_bundle
    commands = [
        task_command(title="第二项", due_at=None),
        task_command(
            title="第一项",
            due_at=datetime(2026, 8, 12, 8, 0, tzinfo=timezone.utc),
        ),
        CreateItemCommand(
            collection_id="collection_local",
            type=ItemType.NOTE,
            title="无时间笔记",
            timezone="UTC",
        ),
    ]
    for index, command in enumerate(commands):
        service.create_item(command, idempotency_key=f"create-{index}")

    first = service.list_items(limit=2)
    second = service.list_items(limit=2, cursor=first.next_cursor)

    assert first.has_more is True
    assert first.next_cursor is not None
    assert [item.title for item in first.items] == ["第一项", "第二项"]
    assert [item.title for item in second.items] == ["无时间笔记"]
    assert second.has_more is False

    with pytest.raises(InvalidCursorError):
        service.list_items(cursor="not-a-cursor")


def test_item_api_crud_and_uniform_errors(tmp_path):
    settings = Settings.model_validate(
        {
            "storage": {
                "driver": "sqlite",
                "sqlite_path": str(tmp_path / "api.sqlite3"),
            },
            "app": {"instance_name": "api-test"},
        }
    )

    with TestClient(create_app(settings)) as client:
        missing_key = client.post(
            "/v1/items",
            json={
                "collection_id": "collection_local",
                "type": "task",
                "title": "提交报告",
                "due_at": "2026-08-14T18:00:00Z",
                "timezone": "UTC",
            },
        )
        assert missing_key.status_code == 400
        assert missing_key.json()["error"]["code"] == "validation_error"

        created = client.post(
            "/v1/items",
            headers={"Idempotency-Key": "api-create"},
            json={
                "collection_id": "collection_local",
                "type": "task",
                "title": "提交报告",
                "due_at": "2026-08-14T18:00:00Z",
                "timezone": "UTC",
                "reminders": [
                    {"mode": ReminderMode.RELATIVE.value, "minutes_before": 30}
                ],
            },
        )
        assert created.status_code == 201
        item = created.json()
        assert item["version"] == 1
        assert len(item["reminders"]) == 1

        replay = client.post(
            "/v1/items",
            headers={"Idempotency-Key": "api-create"},
            json={
                "collection_id": "collection_local",
                "type": "task",
                "title": "提交报告",
                "due_at": "2026-08-14T18:00:00Z",
                "timezone": "UTC",
                "reminders": [
                    {"mode": ReminderMode.RELATIVE.value, "minutes_before": 30}
                ],
            },
        )
        assert replay.json() == item

        updated = client.patch(
            f"/v1/items/{item['id']}",
            json={
                "expected_version": 1,
                "patch": {"title": "提交最终报告"},
            },
        )
        assert updated.status_code == 200
        assert updated.json()["version"] == 2

        stale = client.patch(
            f"/v1/items/{item['id']}",
            headers={"X-Request-Id": "request-stale"},
            json={
                "expected_version": 1,
                "patch": {"title": "过期更新"},
            },
        )
        assert stale.status_code == 409
        assert stale.json()["error"] == {
            "code": "version_conflict",
            "message": (
                f"Item {item['id']!r} version conflict: expected 1, found 2"
            ),
            "details": {
                "entity_type": "Item",
                "entity_id": item["id"],
                "expected_version": 1,
                "actual_version": 2,
            },
            "request_id": "request-stale",
        }

        page = client.get("/v1/items", params={"limit": 1}).json()
        assert page["data"][0]["id"] == item["id"]
        assert page["has_more"] is False

        deleted = client.delete(
            f"/v1/items/{item['id']}", params={"expected_version": 2}
        )
        assert deleted.status_code == 200
        assert deleted.json()["deleted_at"] is not None
        assert client.get(f"/v1/items/{item['id']}").status_code == 404
