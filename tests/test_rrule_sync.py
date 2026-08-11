"""T3.3 recurrence expansion and stable external ID synchronization tests."""

from datetime import datetime, timedelta, timezone

from src.application import (
    CreateSubscriptionCommand,
    FetchResponse,
    ItemService,
    SubscriptionRefreshService,
    SubscriptionService,
)
from src.storage import ItemQuery, SQLiteRepository


NOW = datetime(2026, 8, 12, 8, 0, tzinfo=timezone.utc)
RECURRING_ICS = """BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
UID:daily-1
DTSTART:20260813T100000Z
DTEND:20260813T103000Z
SUMMARY:每日同步
RRULE:FREQ=DAILY;COUNT=3
EXDATE:20260814T100000Z
END:VEVENT
END:VCALENDAR
""".encode()
SINGLE_ICS = """BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
UID:daily-2
DTSTART:20260813T100000Z
DTEND:20260813T103000Z
SUMMARY:每日同步
END:VEVENT
END:VCALENDAR
""".encode()


class Clock:
    def __init__(self):
        self.value = NOW

    def __call__(self):
        self.value += timedelta(seconds=1)
        return self.value


class Ids:
    def __init__(self, prefix=""):
        self.index = 0
        self.prefix = prefix

    def __call__(self, value):
        self.index += 1
        return f"{self.prefix}{value}_{self.index}"


class FakeFetcher:
    def __init__(self, *responses):
        self.responses = list(responses)

    def fetch(self, url, *, headers, timeout_seconds):
        return self.responses.pop(0)


def test_rrule_exdate_expands_to_stable_occurrences_and_remote_delete(tmp_path):
    repository = SQLiteRepository(tmp_path / "recurrence.sqlite3")
    subscription = SubscriptionService(
        repository,
        device_id="test-device",
        clock=Clock(),
        id_factory=Ids(),
    ).create_subscription(
        CreateSubscriptionCommand(
            url="https://calendar.example.com/feed.ics", title="团队日历"
        ),
        idempotency_key="create-subscription",
    )
    fetcher = FakeFetcher(
        FetchResponse(200, {"etag": '"r1"'}, RECURRING_ICS),
        FetchResponse(200, {"etag": '"r2"'}, SINGLE_ICS),
    )
    service = SubscriptionRefreshService(
        repository,
        device_id="test-device",
        fetcher=fetcher,
        clock=Clock(),
        id_factory=Ids("refresh_"),
    )

    first = service.refresh(subscription.id, idempotency_key="recurrence-1")
    item_service = ItemService(repository, device_id="test-device")
    first_page = item_service.list_items(
        collection_id=subscription.collection_id,
        from_at=datetime(2026, 8, 13, tzinfo=timezone.utc),
        to_at=datetime(2026, 8, 17, tzinfo=timezone.utc),
    )
    second_page = item_service.list_items(
        collection_id=subscription.collection_id,
        from_at=datetime(2026, 8, 13, tzinfo=timezone.utc),
        to_at=datetime(2026, 8, 17, tzinfo=timezone.utc),
    )
    assert first.created == 1
    assert [item.start_at.day for item in first_page.items] == [13, 15]
    assert [item.id for item in first_page.items] == [item.id for item in second_page.items]

    second = service.refresh(subscription.id, idempotency_key="recurrence-2")
    assert second.deleted == 1
    assert len(repository.list_items(ItemQuery(include_deleted=True))) == 2
    repository.close()
