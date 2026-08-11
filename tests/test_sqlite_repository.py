"""Integration tests for the transactional local SQLite repository."""

from datetime import datetime, timedelta, timezone
import sqlite3

import pytest

from config.loader import Settings
from src.domain import (
    ChangeOperation,
    Collection,
    CollectionKind,
    Item,
    ItemSource,
    ItemStatus,
    ItemType,
    OutboxEntry,
    Reminder,
    ReminderMode,
    Subscription,
    SyncChange,
    SyncEntityType,
)
from src.storage import (
    ConstraintViolationError,
    EntityAlreadyExistsError,
    ItemQuery,
    LATEST_SCHEMA_VERSION,
    RepositoryError,
    SQLiteRepository,
    VersionConflictError,
)


BASE_TIME = datetime(2026, 8, 11, 8, 0, tzinfo=timezone.utc)


def make_collection(**overrides) -> Collection:
    values = {
        "id": "collection_local",
        "name": "我的日程",
        "created_at": BASE_TIME,
        "updated_at": BASE_TIME,
    }
    values.update(overrides)
    return Collection(**values)


def make_item(**overrides) -> Item:
    values = {
        "id": "item_001",
        "collection_id": "collection_local",
        "type": ItemType.EVENT,
        "title": "项目同步",
        "start_at": datetime(2026, 8, 12, 10, 0),
        "end_at": datetime(2026, 8, 12, 10, 30),
        "timezone": "Asia/Shanghai",
        "reminders": [
            Reminder(
                id="reminder_z",
                item_id="item_001",
                mode=ReminderMode.RELATIVE,
                minutes_before=30,
            ),
            Reminder(
                id="reminder_a",
                item_id="item_001",
                mode=ReminderMode.ABSOLUTE,
                remind_at=datetime(2026, 8, 12, 1, 0, tzinfo=timezone.utc),
            ),
        ],
        "created_at": BASE_TIME,
        "updated_at": BASE_TIME,
    }
    values.update(overrides)
    return Item(**values)


def make_outbox(item: Item, change_id: str = "change_001") -> OutboxEntry:
    return OutboxEntry(
        change=SyncChange(
            change_id=change_id,
            device_id="macbook-01",
            entity_type=SyncEntityType.ITEM,
            entity_id=item.id,
            operation=ChangeOperation.CREATE,
            version=item.version,
            updated_at=item.updated_at,
            payload=item.to_dict(),
        ),
        created_at=item.updated_at,
    )


@pytest.fixture
def repository(tmp_path):
    repo = SQLiteRepository(tmp_path / "easycalendar.sqlite3")
    yield repo
    repo.close()


def test_initializes_versioned_schema_and_loads_path_from_settings(tmp_path):
    database_path = tmp_path / "nested" / "app.sqlite3"
    settings = Settings.model_validate(
        {"storage": {"driver": "sqlite", "sqlite_path": str(database_path)}}
    )

    with SQLiteRepository.from_settings(settings) as repository:
        assert repository.schema_version == LATEST_SCHEMA_VERSION
        assert database_path.exists()

    with sqlite3.connect(database_path) as connection:
        tables = {
            row[0]
            for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type = 'table'"
            )
        }
        migrations = connection.execute(
            "SELECT version, name FROM schema_migrations ORDER BY version"
        ).fetchall()

    assert {
        "collections",
        "items",
        "reminders",
        "subscriptions",
        "outbox",
        "sync_state",
        "idempotency_records",
        "candidate_extractions",
        "candidate_confirmations",
    } <= tables
    assert migrations == [
        (1, "001_initial.sql"),
        (2, "002_idempotency.sql"),
        (3, "003_candidate_extractions.sql"),
    ]


def test_auto_migrate_setting_refuses_an_uninitialized_database(tmp_path):
    settings = Settings.model_validate(
        {
            "storage": {
                "driver": "sqlite",
                "sqlite_path": str(tmp_path / "uninitialized.sqlite3"),
            },
            "deployment": {"auto_migrate": False},
        }
    )

    with pytest.raises(RepositoryError, match="auto_migrate is false"):
        SQLiteRepository.from_settings(settings)


def test_item_reminders_and_outbox_survive_repository_restart(tmp_path):
    database_path = tmp_path / "app.sqlite3"
    item = make_item()
    entry = make_outbox(item)

    first = SQLiteRepository(database_path)
    first.create_collection(make_collection())
    with first.transaction() as transaction:
        transaction.create_item(item)
        transaction.create_outbox_entry(entry)
    first.close()

    with SQLiteRepository(database_path) as reopened:
        assert reopened.get_item(item.id) == item
        assert [reminder.id for reminder in reopened.get_item(item.id).reminders] == [
            "reminder_z",
            "reminder_a",
        ]
        assert reopened.get_outbox_entry(entry.change.change_id) == entry
        assert reopened.list_pending_outbox() == [entry]


def test_transaction_rolls_back_item_and_outbox_together(repository):
    repository.create_collection(make_collection())
    item = make_item()
    entry = make_outbox(item)

    with pytest.raises(EntityAlreadyExistsError):
        with repository.transaction() as transaction:
            transaction.create_item(item)
            transaction.create_outbox_entry(entry)
            transaction.create_outbox_entry(entry)

    assert repository.get_item(item.id) is None
    assert repository.get_outbox_entry(entry.change.change_id) is None


def test_failed_compound_write_rolls_back_to_savepoint(repository):
    repository.create_collection(make_collection())
    original = make_item()
    repository.create_item(original)
    duplicate_reminder = Reminder(
        id=original.reminders[0].id,
        item_id="item_002",
        mode=ReminderMode.RELATIVE,
        minutes_before=10,
    )
    conflicting = make_item(
        id="item_002",
        reminders=[duplicate_reminder],
    )

    with repository.transaction() as transaction:
        with pytest.raises(EntityAlreadyExistsError):
            transaction.create_item(conflicting)
        transaction.set_sync_state("write_continued", True, now=BASE_TIME)

    assert repository.get_item(conflicting.id) is None
    assert repository.get_item(original.id) == original
    assert repository.get_sync_state("write_continued") is True


def test_transaction_session_cannot_be_reused_after_commit(repository):
    with repository.transaction() as transaction:
        transaction.create_collection(make_collection())

    with pytest.raises(RepositoryError, match="session is closed"):
        transaction.list_collections()


def test_update_uses_optimistic_version_and_replaces_reminders(repository):
    repository.create_collection(make_collection())
    repository.create_item(make_item())
    current = repository.get_item("item_001")
    stale = Item.from_json(current.to_json())

    current.title = "更新后的项目同步"
    current.reminders = current.reminders[:1]
    current.record_update(now=BASE_TIME + timedelta(minutes=1))
    repository.update_item(current, expected_version=1)

    stored = repository.get_item(current.id)
    assert stored.title == "更新后的项目同步"
    assert stored.version == 2
    assert [reminder.id for reminder in stored.reminders] == ["reminder_z"]

    stale.title = "过期更新"
    stale.record_update(now=BASE_TIME + timedelta(minutes=2))
    with pytest.raises(VersionConflictError) as error:
        repository.update_item(stale, expected_version=1)

    assert error.value.actual == 2
    assert repository.get_item(current.id).title == "更新后的项目同步"


def test_write_revalidates_mutated_domain_objects(repository):
    repository.create_collection(make_collection())
    original = make_item()
    repository.create_item(original)
    invalid = repository.get_item(original.id)
    invalid.title = " "
    invalid.record_update(now=BASE_TIME + timedelta(minutes=1))

    with pytest.raises(ConstraintViolationError, match="domain contract"):
        repository.update_item(invalid, expected_version=1)

    assert repository.get_item(original.id) == original


def test_create_only_accepts_active_version_one_entities(repository):
    repository.create_collection(make_collection())

    with pytest.raises(ConstraintViolationError, match="version 1"):
        repository.create_item(
            make_item(id="item_versioned", reminders=[], version=2)
        )


def test_soft_delete_and_restore_control_default_queries(repository):
    repository.create_collection(make_collection())
    repository.create_item(make_item())
    item = repository.get_item("item_001")

    item.soft_delete(now=BASE_TIME + timedelta(minutes=1))
    repository.update_item(item, expected_version=1)

    assert repository.get_item(item.id) is None
    assert repository.list_items() == []
    tombstone = repository.get_item(item.id, include_deleted=True)
    assert tombstone.version == 2
    assert repository.list_items(ItemQuery(include_deleted=True)) == [tombstone]

    tombstone.restore(now=BASE_TIME + timedelta(minutes=2))
    repository.update_item(tombstone, expected_version=2)

    assert repository.get_item(item.id).version == 3
    assert repository.list_items() == [repository.get_item(item.id)]


def test_item_query_filters_and_orders_schedule_times(repository):
    repository.create_collection(make_collection())
    event = make_item()
    task = make_item(
        id="item_task",
        type=ItemType.TASK,
        title="提交报告",
        start_at=None,
        end_at=None,
        due_at=datetime(2026, 8, 13, 18, 0),
        reminders=[],
        status=ItemStatus.TODO,
        source=ItemSource.LOCAL,
    )
    repository.create_item(task)
    repository.create_item(event)

    results = repository.list_items(
        ItemQuery(
            collection_id="collection_local",
            from_at=datetime(2026, 8, 12, 0, 0, tzinfo=timezone.utc),
            to_at=datetime(2026, 8, 14, 0, 0, tzinfo=timezone.utc),
        )
    )

    assert [item.id for item in results] == ["item_001", "item_task"]
    assert repository.list_items(ItemQuery(item_type=ItemType.EVENT)) == [event]


def test_collection_and_subscription_lifecycle_is_persistent(repository):
    collection = make_collection(
        id="collection_school",
        name="课程表",
        kind=CollectionKind.SUBSCRIPTION,
        readonly=True,
    )
    subscription = Subscription(
        id="subscription_school",
        collection_id=collection.id,
        title="课程表",
        url="https://example.com/calendar.ics",
        created_at=BASE_TIME,
        updated_at=BASE_TIME,
    )
    repository.create_collection(collection)
    repository.create_subscription(subscription)

    subscription.record_failure(
        "upstream timeout", now=BASE_TIME + timedelta(minutes=1)
    )
    repository.update_subscription(subscription, expected_version=1)

    assert repository.get_collection(collection.id) == collection
    assert repository.get_subscription(subscription.id) == subscription
    assert repository.list_subscriptions() == [subscription]

    subscription.soft_delete(now=BASE_TIME + timedelta(minutes=2))
    repository.update_subscription(subscription, expected_version=2)
    assert repository.get_subscription(subscription.id) is None
    tombstone = repository.get_subscription(
        subscription.id, include_deleted=True
    )
    assert tombstone.version == 3


def test_missing_collection_is_reported_as_constraint_violation(repository):
    with pytest.raises(ConstraintViolationError, match="missing collection"):
        repository.create_item(make_item())


def test_outbox_delivery_state_and_sync_cursor_are_durable(tmp_path):
    database_path = tmp_path / "app.sqlite3"
    repository = SQLiteRepository(database_path)
    repository.create_collection(make_collection())
    item = make_item()
    repository.create_item(item)
    entry = make_outbox(item)
    repository.create_outbox_entry(entry)

    entry.record_failure("offline")
    repository.update_outbox_entry(entry)
    repository.set_sync_cursor("cursor_001", now=BASE_TIME)
    repository.close()

    with SQLiteRepository(database_path) as reopened:
        failed = reopened.get_outbox_entry(entry.change.change_id)
        assert failed.retry_count == 1
        assert failed.last_error == "offline"
        assert reopened.get_sync_cursor() == "cursor_001"

        failed.mark_sent(now=BASE_TIME + timedelta(minutes=1))
        reopened.update_outbox_entry(failed)
        assert reopened.list_pending_outbox() == []
        delivered = reopened.get_outbox_entry(entry.change.change_id)
        assert delivered.sent_at == failed.sent_at


def test_outbox_change_is_immutable_after_creation(repository):
    repository.create_collection(make_collection())
    item = make_item()
    repository.create_item(item)
    entry = make_outbox(item)
    repository.create_outbox_entry(entry)

    entry.change.payload["title"] = "mutated after creation"

    with pytest.raises(ConstraintViolationError, match="immutable"):
        repository.update_outbox_entry(entry)

    assert repository.get_outbox_entry(entry.change.change_id).change.payload != (
        entry.change.payload
    )
