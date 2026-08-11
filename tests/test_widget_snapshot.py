"""Tests for the local Widget snapshot contract and file publication."""

from __future__ import annotations

import json
from datetime import datetime, timezone

from src.application import CreateItemCommand, ItemService, UpdateItemCommand
from src.domain import ItemStatus, ItemType
from src.storage import SQLiteRepository
from src.widget import FileWidgetSnapshotWriter, WidgetSnapshotService


SNAPSHOT_TIME = datetime(2026, 8, 12, 1, 30, tzinfo=timezone.utc)


def test_empty_repository_writes_a_valid_empty_snapshot(tmp_path):
    repository = SQLiteRepository(tmp_path / "empty.sqlite3")
    try:
        path = tmp_path / "widget" / "snapshot.json"
        service = WidgetSnapshotService(
            repository,
            FileWidgetSnapshotWriter(path),
            timezone_name="Asia/Shanghai",
            clock=lambda: SNAPSHOT_TIME,
        )

        snapshot = service.refresh()
        payload = json.loads(path.read_text(encoding="utf-8"))

        assert snapshot.version == 0
        assert payload["schema_version"] == 1
        assert payload["timezone"] == "Asia/Shanghai"
        assert payload["today_events"] == []
        assert payload["upcoming_events"] == []
        assert payload["due_items"] == []
        assert payload["items"] == []
        assert list(path.parent.glob("*.tmp")) == []
    finally:
        repository.close()


def test_snapshot_groups_events_and_pending_due_items_by_local_time(tmp_path):
    repository = SQLiteRepository(tmp_path / "items.sqlite3")
    try:
        item_service = ItemService(repository, device_id="widget-test")
        item_service.ensure_default_collection(
            collection_id="collection_local", name="日程", color=None
        )
        today = item_service.create_item(
            CreateItemCommand(
                collection_id="collection_local",
                type=ItemType.EVENT,
                title="今日会议",
                start_at=datetime(2026, 8, 12, 10, 0, tzinfo=timezone.utc),
                timezone="UTC",
            ),
            idempotency_key="today",
        )
        upcoming = item_service.create_item(
            CreateItemCommand(
                collection_id="collection_local",
                type=ItemType.EVENT,
                title="明日会议",
                start_at=datetime(2026, 8, 13, 9, 0, tzinfo=timezone.utc),
                timezone="UTC",
            ),
            idempotency_key="upcoming",
        )
        pending = item_service.create_item(
            CreateItemCommand(
                collection_id="collection_local",
                type=ItemType.TASK,
                title="待处理",
                due_at=datetime(2026, 8, 12, 18, 0, tzinfo=timezone.utc),
                timezone="UTC",
            ),
            idempotency_key="pending",
        )
        done = item_service.create_item(
            CreateItemCommand(
                collection_id="collection_local",
                type=ItemType.TASK,
                title="已完成",
                due_at=datetime(2026, 8, 12, 19, 0, tzinfo=timezone.utc),
                timezone="UTC",
            ),
            idempotency_key="done",
        )
        item_service.complete_task(
            done.id, expected_version=done.version, idempotency_key="done-command"
        )
        cancelled = item_service.create_item(
            CreateItemCommand(
                collection_id="collection_local",
                type=ItemType.EVENT,
                title="已取消",
                start_at=datetime(2026, 8, 12, 11, 0, tzinfo=timezone.utc),
                timezone="UTC",
                status=ItemStatus.CANCELLED,
            ),
            idempotency_key="cancelled",
        )

        service = WidgetSnapshotService(
            repository,
            FileWidgetSnapshotWriter(tmp_path / "snapshot.json"),
            timezone_name="Asia/Shanghai",
            clock=lambda: SNAPSHOT_TIME,
        )
        payload = service.build().to_dict()

        assert [item["id"] for item in payload["today_events"]] == [today.id]
        assert [item["id"] for item in payload["upcoming_events"]] == [upcoming.id]
        assert [item["id"] for item in payload["due_items"]] == [pending.id]
        assert cancelled.id not in {item["id"] for item in payload["items"]}
        assert payload["version"] == 2
        assert all(item["version"] >= 1 for item in payload["items"])
    finally:
        repository.close()


def test_item_service_refreshes_snapshot_after_a_committed_update(tmp_path):
    repository = SQLiteRepository(tmp_path / "refresh.sqlite3")
    try:
        path = tmp_path / "snapshot.json"
        writer = FileWidgetSnapshotWriter(path)
        service = WidgetSnapshotService(
            repository,
            writer,
            timezone_name="Asia/Shanghai",
            clock=lambda: SNAPSHOT_TIME,
        )
        item_service = ItemService(
            repository,
            device_id="widget-test",
            widget_snapshot_callback=service.refresh,
        )
        item_service.ensure_default_collection(
            collection_id="collection_local", name="日程", color=None
        )
        item = item_service.create_item(
            CreateItemCommand(
                collection_id="collection_local",
                type=ItemType.TASK,
                title="旧标题",
                due_at=datetime(2026, 8, 12, 18, 0, tzinfo=timezone.utc),
                timezone="UTC",
            ),
            idempotency_key="create",
        )
        assert json.loads(path.read_text(encoding="utf-8"))["items"][0]["title"] == "旧标题"

        item_service.update_item(
            item.id,
            UpdateItemCommand(expected_version=item.version, values={"title": "新标题"}),
        )
        payload = json.loads(path.read_text(encoding="utf-8"))
        assert payload["items"][0]["title"] == "新标题"
        assert payload["items"][0]["version"] == 2
    finally:
        repository.close()
