"""Tests for transactional JSON backups and ICS Event transfers."""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from config.loader import Settings
from src.application import IdempotencyConflictError, ImportExportService
from src.domain import (
    ChangeOperation,
    Collection,
    CollectionKind,
    Item,
    ItemStatus,
    ItemType,
    OutboxEntry,
    RecurrenceRule,
    Reminder,
    ReminderMode,
    Subscription,
    SyncChange,
    SyncEntityType,
)
from src.main import create_app
from src.storage import SQLiteRepository


NOW = datetime(2026, 8, 11, 8, 0, tzinfo=timezone.utc)


def make_service(repository: SQLiteRepository) -> ImportExportService:
    return ImportExportService(
        repository,
        device_id="test-device",
        timezone_name="Asia/Shanghai",
        default_collection_id="collection_local",
        max_import_bytes=1024 * 1024,
    )


def seed_complete_backup(repository: SQLiteRepository) -> None:
    local = Collection(
        id="collection_local",
        name="我的日程",
        color="#2563EB",
        created_at=NOW,
        updated_at=NOW + timedelta(hours=2),
        version=3,
    )
    subscribed = Collection(
        id="collection_feed",
        name="只读订阅",
        kind=CollectionKind.SUBSCRIPTION,
        readonly=True,
        created_at=NOW,
        updated_at=NOW,
    )
    deleted_at = NOW + timedelta(hours=3)
    item = Item(
        id="item_deleted",
        collection_id=local.id,
        type=ItemType.TASK,
        title="已删除任务",
        due_at=NOW + timedelta(days=1),
        timezone="UTC",
        reminders=[
            Reminder(
                id="reminder_deleted",
                item_id="item_deleted",
                mode=ReminderMode.RELATIVE,
                minutes_before=30,
            )
        ],
        created_at=NOW,
        updated_at=deleted_at,
        deleted_at=deleted_at,
        version=4,
    )
    subscription = Subscription(
        id="subscription_feed",
        collection_id=subscribed.id,
        url="https://calendar.example.com/feed.ics",
        title="团队日历",
        created_at=NOW,
        updated_at=NOW + timedelta(hours=1),
        version=2,
    )
    outbox = OutboxEntry(
        change=SyncChange(
            change_id="change_deleted",
            device_id="test-device",
            entity_type=SyncEntityType.ITEM,
            entity_id=item.id,
            operation=ChangeOperation.DELETE,
            version=item.version,
            updated_at=item.updated_at,
            payload=item.to_dict(),
        ),
        created_at=item.updated_at,
        retry_count=2,
        last_error="offline",
    )
    with repository.transaction() as transaction:
        transaction.restore_collection(local)
        transaction.restore_collection(subscribed)
        transaction.restore_item(item)
        transaction.restore_subscription(subscription)
        transaction.create_outbox_entry(outbox)
        transaction.restore_sync_state(
            "remote_cursor", "cursor_42", updated_at=NOW + timedelta(hours=4)
        )


def comparable_backup(content: str) -> dict:
    value = json.loads(content)
    value.pop("exported_at")
    return value


def test_json_replace_round_trip_preserves_versions_tombstones_and_state(tmp_path):
    source = SQLiteRepository(tmp_path / "source.sqlite3")
    target = SQLiteRepository(tmp_path / "target.sqlite3")
    seed_complete_backup(source)
    target.create_collection(Collection(id="old", name="旧数据"))
    backup = make_service(source).export_json()

    report = make_service(target).import_content(
        format="json",
        mode="commit",
        strategy="replace",
        content=backup,
        idempotency_key="restore-1",
    )

    assert report.accepted is True
    assert report.committed is True
    assert target.get_collection("old", include_deleted=True) is None
    restored = target.get_item("item_deleted", include_deleted=True)
    assert restored is not None
    assert restored.version == 4
    assert restored.deleted_at == NOW + timedelta(hours=3)
    assert restored.reminders[0].id == "reminder_deleted"
    assert comparable_backup(make_service(target).export_json()) == comparable_backup(backup)

    replay = make_service(target).import_content(
        format="json",
        mode="commit",
        strategy="replace",
        content=backup,
        idempotency_key="restore-1",
    )
    assert replay.to_dict() == report.to_dict()


def test_json_merge_skips_equal_data_and_reports_conflict_without_writes(tmp_path):
    repository = SQLiteRepository(tmp_path / "app.sqlite3")
    seed_complete_backup(repository)
    service = make_service(repository)
    backup = service.export_json()

    equal = service.import_content(
        format="json", mode="preview", strategy="merge", content=backup
    )
    assert equal.accepted is True
    assert equal.skipped == {
        "collections": 2,
        "items": 1,
        "subscriptions": 1,
        "outbox": 1,
        "sync_state": 1,
    }

    changed = json.loads(backup)
    changed["collections"][0]["name"] = "冲突名称"
    before = comparable_backup(service.export_json())
    report = service.import_content(
        format="json",
        mode="commit",
        strategy="merge",
        content=json.dumps(changed, ensure_ascii=False),
        idempotency_key="conflict-1",
    )
    assert report.accepted is False
    assert report.committed is False
    assert report.issues[0].code == "conflict"
    assert comparable_backup(service.export_json()) == before


def test_json_invalid_resource_reports_index_and_keeps_database_unchanged(tmp_path):
    repository = SQLiteRepository(tmp_path / "app.sqlite3")
    repository.create_collection(Collection(id="existing", name="保留"))
    service = make_service(repository)
    before = comparable_backup(service.export_json())
    invalid = {
        "schema_version": 1,
        "exported_at": "2026-08-11T08:00:00Z",
        "collections": [Collection(id="new", name="新增").to_dict()],
        "items": [
            {
                "id": "broken",
                "collection_id": "new",
                "type": "event",
                "title": "",
            }
        ],
        "subscriptions": [],
        "outbox": [],
        "sync_state": [],
    }
    report = service.import_content(
        format="json",
        mode="commit",
        strategy="replace",
        content=json.dumps(invalid, ensure_ascii=False),
        idempotency_key="invalid-1",
    )
    assert report.accepted is False
    assert report.issues[0].resource_type == "items"
    assert report.issues[0].index == 0
    assert comparable_backup(service.export_json()) == before


def test_import_idempotency_key_rejects_different_content(tmp_path):
    source = SQLiteRepository(tmp_path / "source.sqlite3")
    target = SQLiteRepository(tmp_path / "target.sqlite3")
    seed_complete_backup(source)
    service = make_service(target)
    backup = make_service(source).export_json()
    service.import_content(
        format="json",
        mode="commit",
        strategy="replace",
        content=backup,
        idempotency_key="same-key",
    )
    changed = json.loads(backup)
    changed["collections"][0]["name"] = "不同"
    with pytest.raises(IdempotencyConflictError):
        service.import_content(
            format="json",
            mode="commit",
            strategy="replace",
            content=json.dumps(changed, ensure_ascii=False),
            idempotency_key="same-key",
        )


def test_ics_round_trip_all_day_timezone_rrule_and_event_only_export(tmp_path):
    source = SQLiteRepository(tmp_path / "source.sqlite3")
    target = SQLiteRepository(tmp_path / "target.sqlite3")
    collection = Collection(id="collection_local", name="我的日程")
    source.create_collection(collection)
    target.create_collection(collection)
    source.create_item(
        Item(
            id="event_all_day",
            collection_id=collection.id,
            type=ItemType.EVENT,
            title="全天例会",
            body="说明",
            start_at=datetime(2026, 8, 12, tzinfo=timezone(timedelta(hours=8))),
            end_at=datetime(2026, 8, 13, tzinfo=timezone(timedelta(hours=8))),
            timezone="Asia/Shanghai",
            all_day=True,
            recurrence=RecurrenceRule(rrule="FREQ=WEEKLY;COUNT=3"),
            tags=["工作", "例会"],
            created_at=NOW,
            updated_at=NOW,
        )
    )
    source.create_item(
        Item(
            id="task_hidden",
            collection_id=collection.id,
            type=ItemType.TASK,
            title="不应导出",
            due_at=NOW + timedelta(days=1),
            created_at=NOW,
            updated_at=NOW,
        )
    )
    content = make_service(source).export_ics()
    assert "BEGIN:VEVENT" in content
    assert "全天例会" in content
    assert "不应导出" not in content
    assert "DTSTART;VALUE=DATE:20260812" in content
    assert "RRULE:FREQ=WEEKLY;COUNT=3" in content

    report = make_service(target).import_content(
        format="ics",
        mode="commit",
        strategy="merge",
        content=content,
        idempotency_key="ics-1",
    )
    assert report.accepted is True
    imported = target.list_items()[0]
    assert imported.type is ItemType.EVENT
    assert imported.title == "全天例会"
    assert imported.all_day is True
    assert imported.start_at.utcoffset() == timedelta(hours=8)
    assert imported.recurrence == RecurrenceRule(rrule="FREQ=WEEKLY;COUNT=3")


def test_ics_duplicates_skip_and_conflicting_batch_is_atomic(tmp_path):
    repository = SQLiteRepository(tmp_path / "app.sqlite3")
    repository.create_collection(Collection(id="collection_local", name="我的日程"))
    service = make_service(repository)
    event = """BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
UID:same@example.com
SUMMARY:同一事件
DTSTART:20260812T090000Z
END:VEVENT
BEGIN:VEVENT
UID:same@example.com
SUMMARY:同一事件
DTSTART:20260812T090000Z
END:VEVENT
END:VCALENDAR
"""
    report = service.import_content(
        format="ics",
        mode="commit",
        strategy="merge",
        content=event,
        idempotency_key="ics-duplicate",
    )
    assert report.created["items"] == 1
    assert report.skipped["items"] == 1
    assert len(repository.list_items()) == 1

    conflict = event.replace("SUMMARY:同一事件", "SUMMARY:冲突事件", 1)
    report = service.import_content(
        format="ics",
        mode="commit",
        strategy="merge",
        content=conflict,
        idempotency_key="ics-conflict",
    )
    assert report.accepted is False
    assert len(repository.list_items()) == 1


def test_ics_invalid_event_rejects_the_whole_batch(tmp_path):
    repository = SQLiteRepository(tmp_path / "app.sqlite3")
    repository.create_collection(Collection(id="collection_local", name="我的日程"))
    content = """BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
UID:valid@example.com
SUMMARY:有效事件
DTSTART:20260812T090000Z
END:VEVENT
BEGIN:VEVENT
UID:invalid@example.com
DTSTART:20260813T090000Z
END:VEVENT
END:VCALENDAR
"""
    report = make_service(repository).import_content(
        format="ics",
        mode="commit",
        strategy="merge",
        content=content,
        idempotency_key="ics-invalid-batch",
    )

    assert report.accepted is False
    assert report.issues[0].resource_type == "events"
    assert report.issues[0].index == 1
    assert repository.list_items() == []


def test_transfer_api_preview_commit_and_content_types(tmp_path):
    repository = SQLiteRepository(tmp_path / "app.sqlite3")
    settings = Settings.model_validate(
        {"storage": {"sqlite_path": str(tmp_path / "unused.sqlite3")}}
    )
    app = create_app(settings, repository=repository)
    content = """BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
UID:api@example.com
SUMMARY:API 事件
DTSTART:20260812T090000Z
END:VEVENT
END:VCALENDAR
"""
    with TestClient(app) as client:
        preview = client.post(
            "/v1/import",
            json={"format": "ics", "mode": "preview", "content": content},
        )
        assert preview.status_code == 200
        assert preview.json()["committed"] is False
        commit = client.post(
            "/v1/import",
            headers={"Idempotency-Key": "api-import"},
            json={"format": "ics", "mode": "commit", "content": content},
        )
        assert commit.status_code == 200
        assert commit.json()["committed"] is True
        json_export = client.get("/v1/export?format=json")
        ics_export = client.get("/v1/export?format=ics")
        assert json_export.headers["content-type"].startswith("application/json")
        assert ics_export.headers["content-type"].startswith("text/calendar")
        assert "API 事件" in ics_export.text
