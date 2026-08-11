"""ICS subscription fetching, conditional requests, and durable refresh state."""

from __future__ import annotations

import hashlib
import json
import socket
import time
from dataclasses import dataclass
from datetime import date, datetime, time as clock_time, timezone
from ipaddress import ip_address
from typing import Any, Callable, Mapping, Optional, Protocol
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, build_opener
from zoneinfo import ZoneInfo

from icalendar import Calendar

from src.domain import (
    ChangeOperation,
    Item,
    ItemSource,
    ItemStatus,
    ItemType,
    RecurrenceRule,
    SourceRef,
    Subscription,
    SyncChange,
    SyncEntityType,
    OutboxEntry,
)
from src.storage import (
    IdempotencyRecord,
    ItemQuery,
    SubscriptionFetchRecord,
)

from .errors import (
    InvalidCommandError,
    SubscriptionNotFoundError,
)
from .ports import SubscriptionRepositoryPort


class ICSFetchError(RuntimeError):
    """An upstream fetch failed before a valid calendar could be applied."""

    def __init__(self, message: str, *, status: Optional[int] = None):
        super().__init__(message)
        self.status = status


@dataclass(frozen=True)
class FetchResponse:
    status: int
    headers: Mapping[str, str]
    body: bytes = b""


class ICSFetcherPort(Protocol):
    def fetch(
        self,
        url: str,
        *,
        headers: Mapping[str, str],
        timeout_seconds: int,
    ) -> FetchResponse: ...


class UrllibICSFetcher:
    """Small dependency-free HTTP client with SSRF and redirect guards."""

    def __init__(
        self,
        *,
        max_bytes: int = 10 * 1024 * 1024,
        retry_attempts: int = 3,
        sleep: Callable[[float], None] = time.sleep,
        resolver: Callable[..., list[tuple[Any, ...]]] = socket.getaddrinfo,
    ):
        if type(max_bytes) is not int or max_bytes < 1024:
            raise ValueError("max_bytes must be at least 1024")
        if type(retry_attempts) is not int or not 1 <= retry_attempts <= 5:
            raise ValueError("retry_attempts must be between 1 and 5")
        self.max_bytes = max_bytes
        self.retry_attempts = retry_attempts
        self._sleep = sleep
        self._resolver = resolver

    def fetch(
        self,
        url: str,
        *,
        headers: Mapping[str, str],
        timeout_seconds: int,
    ) -> FetchResponse:
        self._validate_target(url)
        request = Request(
            url,
            headers={
                "Accept": "text/calendar, text/plain;q=0.9, */*;q=0.1",
                "User-Agent": "EasyCalendar/0.1 ICS subscriber",
                **dict(headers),
            },
            method="GET",
        )
        last_error: Optional[Exception] = None
        for attempt in range(self.retry_attempts):
            try:
                with build_opener(_NoRedirectHandler()).open(
                    request, timeout=timeout_seconds
                ) as response:
                    status = int(response.status)
                    response_headers = {
                        key.lower(): value for key, value in response.headers.items()
                    }
                    if status == 304:
                        return FetchResponse(status, response_headers)
                    if status < 200 or status >= 300:
                        raise ICSFetchError(
                            f"ICS upstream returned HTTP {status}", status=status
                        )
                    body = response.read(self.max_bytes + 1)
                    if len(body) > self.max_bytes:
                        raise ICSFetchError("ICS response exceeds the configured size limit")
                    return FetchResponse(status, response_headers, body)
            except HTTPError as error:
                status = int(error.code)
                if status == 304:
                    return FetchResponse(304, {key.lower(): value for key, value in error.headers.items()})
                last_error = ICSFetchError(
                    f"ICS upstream returned HTTP {status}", status=status
                )
                if status not in {408, 425, 429} and status < 500:
                    break
            except (URLError, TimeoutError, OSError, ICSFetchError) as error:
                last_error = error
                if isinstance(error, ICSFetchError) and error.status is not None and error.status < 500:
                    break
            if attempt + 1 < self.retry_attempts:
                self._sleep(0.25 * (2**attempt))
        if isinstance(last_error, ICSFetchError):
            raise last_error
        raise ICSFetchError(f"ICS fetch failed: {last_error}") from last_error

    def _validate_target(self, url: str) -> None:
        parsed = urlsplit(url)
        if parsed.scheme not in {"http", "https"} or not parsed.hostname:
            raise ICSFetchError("ICS URL must be an absolute HTTP(S) URL")
        hostname = parsed.hostname.rstrip(".").lower()
        if parsed.username or parsed.password or hostname == "localhost" or hostname.endswith(".localhost"):
            raise ICSFetchError("ICS URL target is not allowed")
        try:
            addresses = [ip_address(info[4][0]) for info in self._resolver(hostname, parsed.port or 443, type=socket.SOCK_STREAM)]
        except (OSError, ValueError) as error:
            raise ICSFetchError("ICS URL host could not be resolved") from error
        for address in addresses:
            if (
                address.is_private
                or address.is_loopback
                or address.is_link_local
                or address.is_multicast
                or address.is_unspecified
                or address.is_reserved
            ):
                raise ICSFetchError("ICS URL cannot target a private address")


class _NoRedirectHandler:
    def http_error_301(self, request, response, code, msg, headers):
        raise ICSFetchError("ICS redirects are not allowed", status=code)

    http_error_302 = http_error_301
    http_error_303 = http_error_301
    http_error_307 = http_error_301
    http_error_308 = http_error_301


@dataclass(frozen=True)
class RefreshReport:
    status: str
    subscription_id: str
    http_status: Optional[int] = None
    created: int = 0
    updated: int = 0
    deleted: int = 0
    unchanged: int = 0
    last_success_at: Optional[datetime] = None
    last_error: Optional[str] = None
    fetch_id: Optional[str] = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "status": self.status,
            "subscription_id": self.subscription_id,
            "http_status": self.http_status,
            "created": self.created,
            "updated": self.updated,
            "deleted": self.deleted,
            "unchanged": self.unchanged,
            "last_success_at": self.last_success_at.isoformat() if self.last_success_at else None,
            "last_error": self.last_error,
            "fetch_id": self.fetch_id,
        }

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> "RefreshReport":
        timestamp = value.get("last_success_at")
        return cls(
            status=value["status"],
            subscription_id=value["subscription_id"],
            http_status=value.get("http_status"),
            created=value.get("created", 0),
            updated=value.get("updated", 0),
            deleted=value.get("deleted", 0),
            unchanged=value.get("unchanged", 0),
            last_success_at=datetime.fromisoformat(timestamp) if timestamp else None,
            last_error=value.get("last_error"),
            fetch_id=value.get("fetch_id"),
        )


class SubscriptionRefreshService:
    """Fetch an ICS source and atomically apply its current event snapshot."""

    def __init__(
        self,
        repository: SubscriptionRepositoryPort,
        *,
        device_id: str,
        fetcher: Optional[ICSFetcherPort] = None,
        timezone_name: str = "Asia/Shanghai",
        timeout_seconds: int = 20,
        clock: Callable[[], datetime] = lambda: datetime.now(timezone.utc),
        id_factory: Callable[[str], str] = lambda prefix: f"{prefix}_{hashlib.sha256(str(time.time_ns()).encode()).hexdigest()[:20]}",
    ):
        self.repository = repository
        self.device_id = device_id
        self.fetcher = fetcher or UrllibICSFetcher()
        self.timezone = ZoneInfo(timezone_name)
        self.timeout_seconds = timeout_seconds
        self._clock = clock
        self._id_factory = id_factory

    def refresh(self, subscription_id: str, *, idempotency_key: str) -> RefreshReport:
        if not idempotency_key or len(idempotency_key) > 200:
            raise InvalidCommandError("Idempotency-Key is required")
        current = self.repository.get_subscription(subscription_id)
        if current is None:
            raise SubscriptionNotFoundError(f"Subscription {subscription_id!r} was not found")
        with self.repository.transaction() as transaction:
            replay = self._replay(transaction, subscription_id, idempotency_key)
            if replay is not None:
                return replay
        if not current.enabled:
            report = RefreshReport("skipped", subscription_id, last_error="Subscription is disabled")
            self._record_idempotency(subscription_id, idempotency_key, report)
            return report

        started_at = self._now()
        headers = {}
        if current.etag:
            headers["If-None-Match"] = current.etag
        if current.last_modified:
            headers["If-Modified-Since"] = current.last_modified
        try:
            response = self.fetcher.fetch(
                current.url, headers=headers, timeout_seconds=self.timeout_seconds
            )
            if response.status == 304:
                report = self._apply_success(
                    current,
                    started_at=started_at,
                    response=response,
                    items=None,
                    unchanged=True,
                )
            else:
                content_hash = hashlib.sha256(response.body).hexdigest()
                if current.source_hash == f"sha256:{content_hash}":
                    report = self._apply_success(
                        current,
                        started_at=started_at,
                        response=response,
                        items=None,
                        unchanged=True,
                        source_hash=f"sha256:{content_hash}",
                    )
                else:
                    items = self._parse_calendar(response.body, current, started_at)
                    report = self._apply_success(
                        current,
                        started_at=started_at,
                        response=response,
                        items=items,
                        unchanged=False,
                        source_hash=f"sha256:{content_hash}",
                    )
        except (ICSFetchError, ValueError, TypeError) as error:
            report = self._apply_failure(current, started_at, str(error), getattr(error, "status", None))
        self._record_idempotency(subscription_id, idempotency_key, report)
        return report

    def list_fetch_logs(self, subscription_id: str, *, limit: int = 100) -> list[SubscriptionFetchRecord]:
        return self.repository.list_subscription_fetch_logs(subscription_id, limit=limit)

    def _apply_success(
        self,
        snapshot: Subscription,
        *,
        started_at: datetime,
        response: FetchResponse,
        items: Optional[list[Item]],
        unchanged: bool,
        source_hash: Optional[str] = None,
    ) -> RefreshReport:
        finished_at = self._now()
        etag = response.headers.get("etag") or snapshot.etag
        last_modified = response.headers.get("last-modified") or snapshot.last_modified
        source_hash = source_hash or snapshot.source_hash
        with self.repository.transaction() as transaction:
            current = transaction.get_subscription(snapshot.id)
            if current is None:
                raise SubscriptionNotFoundError(f"Subscription {snapshot.id!r} was not found")
            counts = {"created": 0, "updated": 0, "deleted": 0, "unchanged": 0}
            if items is None:
                counts["unchanged"] = len(
                    transaction.list_items(ItemQuery(collection_id=current.collection_id, include_deleted=False, limit=1000))
                )
            else:
                counts = self._apply_items(transaction, current, items, finished_at)
            updated_subscription = Subscription.from_dict(current.to_dict())
            updated_subscription.record_success(
                etag=etag,
                last_modified=last_modified,
                source_hash=source_hash,
                now=finished_at,
            )
            transaction.update_subscription(updated_subscription, expected_version=current.version)
            transaction.create_outbox_entry(self._outbox(updated_subscription, SyncEntityType.SUBSCRIPTION, ChangeOperation.UPDATE, finished_at))
            fetch_id = self._id_factory("fetch")
            transaction.create_subscription_fetch_log(
                SubscriptionFetchRecord(
                    fetch_id=fetch_id,
                    subscription_id=current.id,
                    started_at=started_at,
                    finished_at=finished_at,
                    status="not_modified" if response.status == 304 or unchanged else "success",
                    http_status=response.status,
                    etag=etag,
                    last_modified=last_modified,
                    source_hash=source_hash,
                    created_count=counts["created"],
                    updated_count=counts["updated"],
                    deleted_count=counts["deleted"],
                    unchanged_count=counts["unchanged"],
                )
            )
        return RefreshReport(
            "not_modified" if response.status == 304 or unchanged else "success",
            current.id,
            http_status=response.status,
            last_success_at=finished_at,
            fetch_id=fetch_id,
            **counts,
        )

    def _apply_failure(
        self, snapshot: Subscription, started_at: datetime, message: str, status: Optional[int]
    ) -> RefreshReport:
        finished_at = self._now()
        with self.repository.transaction() as transaction:
            current = transaction.get_subscription(snapshot.id)
            if current is None:
                raise SubscriptionNotFoundError(f"Subscription {snapshot.id!r} was not found")
            failed = Subscription.from_dict(current.to_dict())
            failed.record_failure(message, now=finished_at)
            transaction.update_subscription(failed, expected_version=current.version)
            transaction.create_outbox_entry(self._outbox(failed, SyncEntityType.SUBSCRIPTION, ChangeOperation.UPDATE, finished_at))
            fetch_id = self._id_factory("fetch")
            transaction.create_subscription_fetch_log(
                SubscriptionFetchRecord(
                    fetch_id=fetch_id,
                    subscription_id=current.id,
                    started_at=started_at,
                    finished_at=finished_at,
                    status="failed",
                    http_status=status,
                    error=message,
                )
            )
        return RefreshReport("failed", snapshot.id, http_status=status, last_error=message, fetch_id=fetch_id)

    def _apply_items(self, transaction: Any, subscription: Subscription, incoming: list[Item], now: datetime) -> dict[str, int]:
        existing = transaction.list_items(
            ItemQuery(collection_id=subscription.collection_id, include_deleted=True, limit=1000)
        )
        owned = {
            item.source_ref.external_id: item
            for item in existing
            if item.source_ref is not None
            and item.source_ref.provider == "ics"
            and item.source_ref.subscription_id == subscription.id
            and item.source_ref.external_id
        }
        counts = {"created": 0, "updated": 0, "deleted": 0, "unchanged": 0}
        seen: set[str] = set()
        for item in incoming:
            key = item.source_ref.external_id if item.source_ref else item.id
            seen.add(key)
            previous = owned.get(key)
            if previous is None:
                transaction.create_item(item)
                transaction.create_outbox_entry(self._outbox(item, SyncEntityType.ITEM, ChangeOperation.CREATE, now))
                counts["created"] += 1
                continue
            if self._semantic(previous) == self._semantic(item) and not previous.is_deleted:
                counts["unchanged"] += 1
                continue
            updated = Item.from_dict(item.to_dict())
            updated.id = previous.id
            updated.created_at = previous.created_at
            updated.version = previous.version
            if previous.is_deleted:
                updated.deleted_at = previous.deleted_at
                updated.restore(now=now)
            else:
                updated.record_update(now=now)
            transaction.update_item(updated, expected_version=previous.version)
            transaction.create_outbox_entry(self._outbox(updated, SyncEntityType.ITEM, ChangeOperation.UPDATE, now))
            counts["updated"] += 1
        for key, previous in owned.items():
            if key in seen or previous.is_deleted:
                continue
            deleted = Item.from_dict(previous.to_dict())
            deleted.soft_delete(now=now)
            transaction.update_item(deleted, expected_version=previous.version)
            transaction.create_outbox_entry(self._outbox(deleted, SyncEntityType.ITEM, ChangeOperation.DELETE, now))
            counts["deleted"] += 1
        return counts

    def _parse_calendar(self, body: bytes, subscription: Subscription, now: datetime) -> list[Item]:
        try:
            calendar = Calendar.from_ical(body)
        except Exception as error:
            raise ValueError(f"ICS content is invalid: {error}") from error
        items: list[Item] = []
        for component in calendar.walk():
            if component.name != "VEVENT":
                continue
            items.append(self._event_to_item(component, subscription, now))
        if not items:
            raise ValueError("ICS content contains no VEVENT components")
        return items

    def _event_to_item(self, component: Any, subscription: Subscription, now: datetime) -> Item:
        summary = self._text(component, "SUMMARY")
        if not summary or "DTSTART" not in component:
            raise ValueError("VEVENT SUMMARY and DTSTART are required")
        start = self._ical_datetime(component.decoded("DTSTART"))
        end = self._ical_datetime(component.decoded("DTEND")) if "DTEND" in component else None
        uid = self._text(component, "UID") or hashlib.sha256(f"{summary}|{start.isoformat()}".encode()).hexdigest()[:24]
        recurrence = self._recurrence(component)
        status = ItemStatus.CANCELLED if self._text(component, "STATUS").upper() == "CANCELLED" else ItemStatus.TODO
        canonical = {
            "uid": uid,
            "summary": summary,
            "description": self._text(component, "DESCRIPTION"),
            "location": self._text(component, "LOCATION"),
            "start": start.isoformat(),
            "end": end.isoformat() if end else None,
            "recurrence": recurrence.to_dict() if recurrence else None,
            "status": status.value,
        }
        content_hash = hashlib.sha256(json.dumps(canonical, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
        item_id = "item_ics_" + hashlib.sha256(f"{subscription.id}|{uid}".encode()).hexdigest()[:24]
        return Item(
            id=item_id,
            collection_id=subscription.collection_id,
            type=ItemType.EVENT,
            title=summary,
            body=canonical["description"],
            start_at=start,
            end_at=end,
            timezone=getattr(self.timezone, "key", str(self.timezone)),
            all_day=isinstance(component.decoded("DTSTART"), date) and not isinstance(component.decoded("DTSTART"), datetime),
            location=canonical["location"],
            status=status,
            recurrence=recurrence,
            source=ItemSource.ICS,
            source_ref=SourceRef(provider="ics", external_id=uid, subscription_id=subscription.id, url=subscription.url),
            metadata={"ics_uid": uid, "ics_hash": content_hash},
            created_at=now,
            updated_at=now,
        )

    def _recurrence(self, component: Any) -> Optional[RecurrenceRule]:
        if "RRULE" not in component and "EXDATE" not in component and "RDATE" not in component:
            return None
        rrule = component["RRULE"].to_ical().decode("utf-8") if "RRULE" in component else "FREQ=DAILY"
        exdates = [self._ical_datetime(value.dt).isoformat() for value in self._date_values(component, "EXDATE")]
        rdates = [self._ical_datetime(value.dt).isoformat() for value in self._date_values(component, "RDATE")]
        return RecurrenceRule(rrule=rrule, exdates=exdates, rdates=rdates)

    @staticmethod
    def _date_values(component: Any, name: str) -> list[Any]:
        values: list[Any] = []
        property_value = component.get(name)
        if property_value is None:
            return values
        candidates = property_value if isinstance(property_value, list) else [property_value]
        for candidate in candidates:
            values.extend(getattr(candidate, "dts", [candidate]))
        return values

    def _ical_datetime(self, value: Any) -> datetime:
        if isinstance(value, datetime):
            if value.tzinfo is None or value.utcoffset() is None:
                return value.replace(tzinfo=self.timezone)
            return value
        if isinstance(value, date):
            return datetime.combine(value, clock_time.min, tzinfo=self.timezone)
        raise ValueError("ICS date value is invalid")

    @staticmethod
    def _text(component: Any, name: str) -> str:
        value = component.get(name)
        if value is None:
            return ""
        return str(value).strip()

    @staticmethod
    def _semantic(item: Item) -> dict[str, Any]:
        data = item.to_dict()
        for key in ("id", "created_at", "updated_at", "deleted_at", "version"):
            data.pop(key, None)
        return data

    def _outbox(self, entity: Any, entity_type: SyncEntityType, operation: ChangeOperation, timestamp: datetime) -> OutboxEntry:
        return OutboxEntry(
            change=SyncChange(
                change_id=self._id_factory("change"),
                device_id=self.device_id,
                entity_type=entity_type,
                entity_id=entity.id,
                operation=operation,
                version=entity.version,
                updated_at=entity.updated_at,
                payload=entity.to_dict(),
            ),
            created_at=timestamp,
        )

    def _now(self) -> datetime:
        value = self._clock()
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("Refresh clock must return an aware datetime")
        return value

    def _record_idempotency(self, subscription_id: str, key: str, report: RefreshReport) -> None:
        with self.repository.transaction() as transaction:
            transaction.create_idempotency_record(
                IdempotencyRecord(
                    scope=f"subscriptions:{subscription_id}:refresh",
                    key=key.strip(),
                    request_hash=subscription_id,
                    response_json=json.dumps(report.to_dict(), sort_keys=True),
                    created_at=self._now(),
                )
            )

    def _replay(self, transaction: Any, subscription_id: str, key: str) -> Optional[RefreshReport]:
        record = transaction.get_idempotency_record(f"subscriptions:{subscription_id}:refresh", key.strip())
        if record is None:
            return None
        try:
            return RefreshReport.from_dict(json.loads(record.response_json))
        except (TypeError, ValueError, KeyError, json.JSONDecodeError) as error:
            raise InvalidCommandError("Stored refresh response is invalid") from error
