"""T3.1 subscription and read-only Collection use cases."""

from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from config.loader import Settings
from src.application import (
    CreateItemCommand,
    CreateSubscriptionCommand,
    ItemService,
    ReadonlyCollectionError,
    SubscriptionService,
    UpdateSubscriptionCommand,
)
from src.domain import CollectionKind, ItemType, Subscription, SyncEntityType
from src.main import create_app
from src.storage import SQLiteRepository


BASE_TIME = datetime(2026, 8, 12, 8, 0, tzinfo=timezone.utc)


class Clock:
    def __init__(self):
        self.value = BASE_TIME

    def __call__(self):
        self.value += timedelta(seconds=1)
        return self.value


class Ids:
    def __init__(self):
        self.value = 0

    def __call__(self, prefix):
        self.value += 1
        return f"{prefix}_{self.value}"


@pytest.fixture
def services(tmp_path):
    repository = SQLiteRepository(tmp_path / "subscriptions.sqlite3")
    service = SubscriptionService(
        repository, device_id="test-device", clock=Clock(), id_factory=Ids()
    )
    yield service, repository
    repository.close()


def test_create_subscription_creates_readonly_collection_and_outbox(services):
    service, repository = services
    command = CreateSubscriptionCommand(
        url="https://calendar.example.com/public.ics", title="公开课程表"
    )

    created = service.create_subscription(command, idempotency_key="sub-create")
    replayed = service.create_subscription(command, idempotency_key="sub-create")

    assert replayed == created
    collection = repository.get_collection(created.collection_id)
    assert collection.kind is CollectionKind.SUBSCRIPTION
    assert collection.readonly is True
    assert [entry.change.entity_type for entry in repository.list_pending_outbox()] == [
        SyncEntityType.COLLECTION,
        SyncEntityType.SUBSCRIPTION,
    ]


def test_subscription_patch_and_delete_are_versioned(services):
    service, repository = services
    created = service.create_subscription(
        CreateSubscriptionCommand(
            url="https://calendar.example.com/public.ics", title="公开课程表"
        ),
        idempotency_key="sub-create",
    )

    updated = service.update_subscription(
        created.id,
        UpdateSubscriptionCommand(
            expected_version=1,
            values={"title": "新标题", "enabled": False, "refresh_interval_minutes": 30},
        ),
    )
    assert updated.version == 2
    assert updated.enabled is False
    assert updated.metadata["refresh_interval_minutes"] == 30

    deleted = service.delete_subscription(created.id, expected_version=2)
    assert deleted.deleted_at is not None
    assert repository.get_subscription(created.id) is None
    assert repository.get_subscription(created.id, include_deleted=True) == deleted


def test_subscription_collection_rejects_normal_item_writes(services):
    service, repository = services
    subscription = service.create_subscription(
        CreateSubscriptionCommand(
            url="https://calendar.example.com/public.ics", title="公开课程表"
        ),
        idempotency_key="sub-create",
    )
    item_service = ItemService(repository, device_id="test-device")

    with pytest.raises(ReadonlyCollectionError):
        item_service.create_item(
            CreateItemCommand(
                collection_id=subscription.collection_id,
                type=ItemType.TASK,
                title="不应写入",
                timezone="UTC",
            ),
            idempotency_key="item-create",
        )


@pytest.mark.parametrize(
    "url",
    ["ftp://calendar.example.com/feed.ics", "https://localhost/feed.ics", "https://127.0.0.1/feed.ics", "https://u:p@example.com/feed.ics"],
)
def test_subscription_url_validation(url):
    with pytest.raises(ValueError, match="Subscription url"):
        Subscription(
            id="sub_invalid",
            collection_id="collection_feed",
            url=url,
            title="无效",
            created_at=BASE_TIME,
            updated_at=BASE_TIME,
        )


def test_subscription_api_crud(tmp_path):
    settings = Settings.model_validate(
        {
            "storage": {"driver": "sqlite", "sqlite_path": str(tmp_path / "api.sqlite3")},
            "app": {"instance_name": "api-test"},
        }
    )
    with TestClient(create_app(settings)) as client:
        response = client.post(
            "/v1/subscriptions",
            headers={"Idempotency-Key": "sub-create"},
            json={"url": "https://calendar.example.com/public.ics", "title": "公开课程表"},
        )
        assert response.status_code == 201
        subscription = response.json()
        collection = client.get(f"/v1/collections/{subscription['collection_id']}").json()
        assert collection["readonly"] is True

        patched = client.patch(
            f"/v1/subscriptions/{subscription['id']}",
            json={"expected_version": 1, "patch": {"enabled": False}},
        )
        assert patched.status_code == 200
        assert patched.json()["enabled"] is False

        denied = client.post(
            "/v1/items",
            headers={"Idempotency-Key": "item-create"},
            json={
                "collection_id": subscription["collection_id"],
                "type": "task",
                "title": "不能直接写",
                "timezone": "UTC",
            },
        )
        assert denied.status_code == 403
        assert denied.json()["error"]["code"] == "readonly_collection"
