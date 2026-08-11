"""T3.2 conditional ICS fetching and refresh audit tests."""

from datetime import datetime, timedelta, timezone

from src.application import (
    CreateSubscriptionCommand,
    FetchResponse,
    ICSFetchError,
    SubscriptionRefreshService,
    SubscriptionService,
)
from src.domain import ItemSource
from src.storage import SQLiteRepository


NOW = datetime(2026, 8, 12, 8, 0, tzinfo=timezone.utc)
ICS = """BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
UID:meeting-1
DTSTART:20260813T100000Z
DTEND:20260813T103000Z
SUMMARY:项目同步
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
    def __init__(self):
        self.index = 0

    def __call__(self, prefix):
        self.index += 1
        return f"{prefix}_{self.index}"


class RefreshIds(Ids):
    def __call__(self, prefix):
        return f"refresh_{super().__call__(prefix)}"


class FakeFetcher:
    def __init__(self, *responses):
        self.responses = list(responses)
        self.calls = []

    def fetch(self, url, *, headers, timeout_seconds):
        self.calls.append((url, dict(headers), timeout_seconds))
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return response


def make_subscription(repository):
    return SubscriptionService(
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


def test_refresh_applies_ics_and_uses_conditional_not_modified(tmp_path):
    repository = SQLiteRepository(tmp_path / "refresh.sqlite3")
    subscription = make_subscription(repository)
    fetcher = FakeFetcher(
        FetchResponse(200, {"etag": '"v1"', "last-modified": "Wed, 12 Aug 2026 00:00:00 GMT"}, ICS),
        FetchResponse(304, {"etag": '"v1"'}),
    )
    service = SubscriptionRefreshService(
        repository,
        device_id="test-device",
        fetcher=fetcher,
        clock=Clock(),
        id_factory=RefreshIds(),
    )

    first = service.refresh(subscription.id, idempotency_key="refresh-1")
    second = service.refresh(subscription.id, idempotency_key="refresh-2")

    assert first.status == "success"
    assert first.created == 1
    assert second.status == "not_modified"
    assert second.unchanged == 1
    items = repository.list_items()
    assert len(items) == 1
    assert items[0].source is ItemSource.ICS
    assert items[0].source_ref.external_id == "meeting-1"
    assert fetcher.calls[1][1]["If-None-Match"] == '"v1"'
    assert len(service.list_fetch_logs(subscription.id)) == 2
    repository.close()


def test_refresh_failure_is_queryable_and_idempotent(tmp_path):
    repository = SQLiteRepository(tmp_path / "failure.sqlite3")
    subscription = make_subscription(repository)
    fetcher = FakeFetcher(ICSFetchError("upstream timeout"))
    service = SubscriptionRefreshService(
        repository,
        device_id="test-device",
        fetcher=fetcher,
        clock=Clock(),
        id_factory=RefreshIds(),
    )

    failed = service.refresh(subscription.id, idempotency_key="refresh-failure")
    replayed = service.refresh(subscription.id, idempotency_key="refresh-failure")

    assert failed.status == "failed"
    assert replayed == failed
    assert len(fetcher.calls) == 1
    stored = repository.get_subscription(subscription.id)
    assert stored.last_error == "upstream timeout"
    assert service.list_fetch_logs(subscription.id)[0].status == "failed"
    repository.close()
