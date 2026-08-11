"""Tests for stable, dependency-free domain contracts."""

import json
from datetime import datetime, timedelta, timezone

import pytest

from src.domain import (
    DOMAIN_SCHEMA_VERSION,
    CandidateItem,
    ChangeOperation,
    Collection,
    CollectionKind,
    Item,
    ItemSource,
    ItemStatus,
    ItemType,
    OutboxEntry,
    RecurrenceRule,
    Reminder,
    ReminderMode,
    ReminderSuggestion,
    SourceRef,
    SourceTextSpan,
    Subscription,
    SyncChange,
    SyncEntityType,
)
from src.parser.rule_parser import RuleParser


BASE_TIME = datetime(2026, 8, 11, 8, 0, tzinfo=timezone.utc)


def make_item(**overrides) -> Item:
    values = {
        "id": "item_001",
        "collection_id": "collection_local",
        "type": ItemType.EVENT,
        "title": "项目同步",
        "start_at": datetime(2026, 8, 12, 10, 0),
        "end_at": datetime(2026, 8, 12, 10, 30),
        "timezone": "Asia/Shanghai",
        "created_at": BASE_TIME,
        "updated_at": BASE_TIME,
    }
    values.update(overrides)
    return Item(**values)


def make_change(**overrides) -> SyncChange:
    values = {
        "change_id": "chg_001",
        "device_id": "macbook-01",
        "entity_type": SyncEntityType.ITEM,
        "entity_id": "item_001",
        "operation": ChangeOperation.UPDATE,
        "version": 2,
        "updated_at": BASE_TIME,
        "payload": {"title": "项目同步"},
    }
    values.update(overrides)
    return SyncChange(**values)


def test_candidate_is_not_a_formal_item_until_promoted():
    candidate = CandidateItem(
        temp_id="cand_001",
        type=ItemType.TASK,
        title="提交设计稿",
        due_at=datetime(2026, 8, 14, 18, 0),
        confidence=0.82,
        reminders=[
            ReminderSuggestion(
                mode=ReminderMode.RELATIVE,
                minutes_before=1440,
                reason="截止日前一天提醒",
            )
        ],
    )

    assert not hasattr(candidate, "id")

    item = candidate.to_item(
        collection_id="local",
        item_id="item_001",
        source=ItemSource.AI,
        now=BASE_TIME,
    )

    assert item.id == "item_001"
    assert item.type is ItemType.TASK
    assert item.status is ItemStatus.TODO
    assert item.source is ItemSource.AI
    assert item.due_at.isoformat() == "2026-08-14T18:00:00+08:00"
    assert item.created_at == BASE_TIME
    assert item.reminders[0].item_id == item.id
    assert item.reminders[0].minutes_before == 1440


def test_candidate_rejects_invalid_confidence():
    with pytest.raises(ValueError, match="confidence"):
        CandidateItem(
            temp_id="cand_001",
            type="event",
            title="会议",
            confidence=1.1,
        )


def test_rule_parser_returns_event_and_due_candidates():
    parser = RuleParser(datetime(2026, 8, 11, 8, 0))
    result = parser.parse("明天上午9点开会，然后周五前提交设计稿")

    assert [candidate.type for candidate in result.candidates] == [
        ItemType.EVENT,
        ItemType.TASK,
    ]
    assert result.candidates[0].start_at == datetime(2026, 8, 12, 9, 0)
    assert result.candidates[1].due_at == datetime(2026, 8, 14, 0, 0)
    assert (
        result.candidates[1].source_text_span.start
        > result.candidates[0].source_text_span.end
    )
    assert len(result.candidates) == 2


def test_item_normalizes_schedule_timezone_and_rejects_invalid_ranges():
    item = make_item()

    assert item.start_at.isoformat() == "2026-08-12T10:00:00+08:00"
    assert item.end_at.isoformat() == "2026-08-12T10:30:00+08:00"

    with pytest.raises(ValueError, match="before start_at"):
        make_item(
            start_at=datetime(2026, 8, 12, 11, 0),
            end_at=datetime(2026, 8, 12, 10, 0),
        )

    with pytest.raises(ValueError, match="require start_at"):
        make_item(start_at=None, end_at=None)


def test_versioned_item_update_delete_and_restore_are_monotonic_and_idempotent():
    item = make_item()

    assert item.record_update(now=BASE_TIME + timedelta(minutes=1)) == 2
    assert item.soft_delete(now=BASE_TIME + timedelta(minutes=2)) is True
    assert item.version == 3
    assert item.soft_delete(now=BASE_TIME + timedelta(minutes=3)) is False
    assert item.version == 3
    with pytest.raises(ValueError, match="restored"):
        item.record_update(now=BASE_TIME + timedelta(minutes=3))

    assert item.restore(now=BASE_TIME + timedelta(minutes=4)) is True
    assert item.version == 4
    assert item.deleted_at is None
    assert item.restore(now=BASE_TIME + timedelta(minutes=5)) is False
    assert item.version == 4


def test_versioned_entities_reject_naive_audit_times_and_time_travel():
    with pytest.raises(ValueError, match="created_at.*timezone"):
        make_item(
            created_at=datetime(2026, 8, 11, 8, 0),
            updated_at=datetime(2026, 8, 11, 8, 0),
        )

    item = make_item()
    with pytest.raises(ValueError, match="before updated_at"):
        item.record_update(now=BASE_TIME - timedelta(seconds=1))


def test_collection_enforces_readonly_subscription_boundary():
    with pytest.raises(ValueError, match="must be readonly"):
        Collection(
            id="collection_school",
            name="课程表",
            kind=CollectionKind.SUBSCRIPTION,
            readonly=False,
            created_at=BASE_TIME,
            updated_at=BASE_TIME,
        )

    collection = Collection(
        id="collection_school",
        name="课程表",
        kind=CollectionKind.SUBSCRIPTION,
        color="#2563EB",
        readonly=True,
        created_at=BASE_TIME,
        updated_at=BASE_TIME,
    )

    assert collection.readonly is True
    assert collection.kind is CollectionKind.SUBSCRIPTION


def test_subscription_refresh_transitions_preserve_last_success():
    subscription = Subscription(
        id="sub_001",
        collection_id="collection_school",
        url="https://example.com/calendar.ics",
        title="课程表",
        created_at=BASE_TIME,
        updated_at=BASE_TIME,
    )

    assert subscription.set_enabled(False, now=BASE_TIME + timedelta(minutes=1))
    subscription.record_failure(
        "upstream timeout", now=BASE_TIME + timedelta(minutes=2)
    )
    assert subscription.version == 3
    assert subscription.last_error == "upstream timeout"
    assert subscription.last_success_at is None

    subscription.record_success(
        etag="abc123",
        source_hash="sha256:123",
        now=BASE_TIME + timedelta(minutes=3),
    )
    assert subscription.version == 4
    assert subscription.last_success_at == BASE_TIME + timedelta(minutes=3)
    assert subscription.last_error is None
    assert subscription.etag == "abc123"
    assert subscription.set_enabled(False, now=BASE_TIME + timedelta(minutes=4)) is False


def test_subscription_rejects_stale_transition_without_partial_mutation():
    subscription = Subscription(
        id="sub_001",
        collection_id="collection_school",
        url="https://example.com/calendar.ics",
        title="课程表",
        created_at=BASE_TIME,
        updated_at=BASE_TIME,
    )

    with pytest.raises(ValueError, match="before updated_at"):
        subscription.set_enabled(False, now=BASE_TIME - timedelta(seconds=1))

    assert subscription.enabled is True
    assert subscription.version == 1


def test_sync_change_conflict_order_is_deterministic():
    older = make_change(change_id="chg_a", version=2)
    newer_version = make_change(change_id="chg_b", version=3)
    stable_tie_breaker = make_change(change_id="chg_z", version=3)

    assert newer_version.wins_over(older)
    assert stable_tie_breaker.wins_over(newer_version)

    different_entity = make_change(entity_id="item_002")
    with pytest.raises(ValueError, match="different entities"):
        newer_version.wins_over(different_entity)


def test_outbox_tracks_failures_and_sent_state_idempotently():
    outbox = OutboxEntry(change=make_change(), created_at=BASE_TIME)

    outbox.record_failure("offline")
    outbox.record_failure("still offline")
    assert outbox.retry_count == 2
    assert outbox.last_error == "still offline"
    assert outbox.is_pending

    assert outbox.mark_sent(now=BASE_TIME + timedelta(minutes=1)) is True
    assert outbox.last_error is None
    assert not outbox.is_pending
    assert outbox.mark_sent(now=BASE_TIME + timedelta(minutes=2)) is False
    with pytest.raises(ValueError, match="Sent"):
        outbox.record_failure("too late")


def test_item_json_round_trip_preserves_nested_domain_types():
    item = make_item(
        recurrence=RecurrenceRule(
            rrule="FREQ=WEEKLY;BYDAY=MO",
            exdates=["2026-08-17T10:00:00+08:00"],
        ),
        reminders=[
            Reminder(
                id="reminder_001",
                item_id="item_001",
                mode=ReminderMode.RELATIVE,
                minutes_before=30,
            )
        ],
        tags=["工作", "工作", "重点"],
        source=ItemSource.GOOGLE,
        source_ref=SourceRef(provider="google", external_id="google_001"),
        metadata={"attendees": ["user@example.com"], "sequence": 2},
    )
    item.soft_delete(now=BASE_TIME + timedelta(minutes=1))

    encoded = item.to_json()
    decoded = Item.from_json(encoded)
    envelope = json.loads(encoded)

    assert decoded == item
    assert decoded.type is ItemType.EVENT
    assert decoded.reminders[0].mode is ReminderMode.RELATIVE
    assert decoded.source_ref.provider == "google"
    assert decoded.tags == ["工作", "重点"]
    assert decoded.is_deleted
    assert decoded.version == 2
    assert envelope["schema_version"] == DOMAIN_SCHEMA_VERSION
    assert envelope["model"] == "item"


@pytest.mark.parametrize(
    "model",
    [
        CandidateItem(
            temp_id="cand_002",
            type=ItemType.TASK,
            title="提交报告",
            due_at=datetime(2026, 8, 14, 18, 0),
            source_text_span=SourceTextSpan(start=0, end=4),
            confidence=0.8,
        ),
        Collection(
            id="collection_local",
            name="我的日程",
            created_at=BASE_TIME,
            updated_at=BASE_TIME,
        ),
        Subscription(
            id="sub_001",
            collection_id="collection_school",
            url="https://example.com/calendar.ics",
            title="课程表",
            created_at=BASE_TIME,
            updated_at=BASE_TIME,
        ),
        make_change(),
        OutboxEntry(change=make_change(), created_at=BASE_TIME),
    ],
)
def test_sync_domain_models_round_trip_json(model):
    assert type(model).from_json(model.to_json()) == model


def test_serialization_rejects_unknown_fields_wrong_models_and_bad_metadata():
    item_data = make_item().to_dict()
    item_data["future_field"] = True
    with pytest.raises(ValueError, match="Unknown item fields"):
        Item.from_dict(item_data)

    with pytest.raises(ValueError, match="Expected model 'collection'"):
        Collection.from_json(make_item().to_json())

    envelope = json.loads(make_item().to_json())
    envelope["schema_version"] = DOMAIN_SCHEMA_VERSION + 1
    with pytest.raises(ValueError, match="Unsupported domain schema"):
        Item.from_json(json.dumps(envelope))

    envelope["schema_version"] = True
    with pytest.raises(ValueError, match="Unsupported domain schema"):
        Item.from_json(json.dumps(envelope))

    with pytest.raises(ValueError, match="non-JSON"):
        make_item(metadata={"bad": object()})
