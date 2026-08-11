"""Candidate extraction, confirmation, rejection, and API contract tests."""

from __future__ import annotations

from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient

from config.loader import Settings
from src.application import (
    CandidateDecisionConflictError,
    CandidateEditCommand,
    CandidateService,
    ExtractionRejectedError,
    InvalidCommandError,
    ItemService,
    ReminderDraft,
)
from src.domain import CandidateItem, ItemSource, ReminderMode, SyncEntityType
from src.main import create_app
from src.parser.rule_adapter import RuleParserAdapter
from src.storage import SQLiteRepository


BASE_TIME = datetime(2026, 8, 11, 8, 0, tzinfo=timezone.utc)


class SequenceIds:
    def __init__(self) -> None:
        self.value = 0

    def __call__(self, prefix: str) -> str:
        self.value += 1
        return f"{prefix}_{self.value:04d}"


def build_services(repository: SQLiteRepository):
    item_service = ItemService(
        repository,
        device_id="candidate-test",
        clock=lambda: BASE_TIME,
        id_factory=SequenceIds(),
    )
    item_service.ensure_default_collection(
        collection_id="collection_local",
        name="我的日程",
        color="#2563EB",
    )
    candidate_service = CandidateService(
        repository,
        item_service,
        RuleParserAdapter(),
        max_input_chars=20000,
        clock=lambda: BASE_TIME,
        id_factory=SequenceIds(),
    )
    return candidate_service, item_service


def item_outbox(repository: SQLiteRepository):
    return [
        entry
        for entry in repository.list_pending_outbox()
        if entry.change.entity_type is SyncEntityType.ITEM
    ]


def test_extraction_is_a_durable_preview_with_request_timezone(tmp_path):
    database_path = tmp_path / "candidate.sqlite3"
    repository = SQLiteRepository(database_path)
    candidate_service, _ = build_services(repository)

    extraction = candidate_service.extract(
        "明天下午3点开会",
        timezone_name="Asia/Shanghai",
        now=datetime(2026, 8, 11, 10, 0, tzinfo=timezone.utc),
    )

    assert extraction.parser_id == "rules.zh_cn"
    assert len(extraction.candidates) == 1
    assert extraction.candidates[0].timezone == "Asia/Shanghai"
    assert extraction.candidates[0].start_at.isoformat() == "2026-08-12T15:00:00+08:00"
    assert repository.list_items() == []
    assert item_outbox(repository) == []

    repository.close()
    with SQLiteRepository(database_path) as reopened:
        assert reopened.get_candidate_extraction(extraction.extraction_id) == extraction


def test_confirmation_is_atomic_and_idempotent_across_restart(tmp_path):
    database_path = tmp_path / "candidate.sqlite3"
    repository = SQLiteRepository(database_path)
    candidate_service, _ = build_services(repository)
    extraction = candidate_service.extract(
        "明天下午3点开会",
        timezone_name="Asia/Shanghai",
        now=datetime(2026, 8, 11, 10, 0, tzinfo=timezone.utc),
    )
    candidate = extraction.candidates[0]
    edit = CandidateEditCommand(
        collection_id="collection_local",
        values={
            "title": "发布计划评审",
            "tags": ["工作"],
            "metadata": {"user_note": "带会议材料"},
            "reminders": [
                ReminderDraft(
                    mode=ReminderMode.RELATIVE,
                    minutes_before=30,
                )
            ],
        },
    )

    confirmed = candidate_service.confirm(
        extraction_id=extraction.extraction_id,
        candidate=candidate,
        edit=edit,
        idempotency_key="confirm-candidate",
    )
    replayed = candidate_service.confirm(
        extraction_id=extraction.extraction_id,
        candidate=candidate,
        edit=edit,
        idempotency_key="confirm-candidate",
    )
    replayed_with_new_key = candidate_service.confirm(
        extraction_id=extraction.extraction_id,
        candidate=candidate,
        edit=edit,
        idempotency_key="same-decision-new-key",
    )

    assert replayed == confirmed
    assert replayed_with_new_key == confirmed
    assert confirmed.source is ItemSource.AI
    assert confirmed.title == "发布计划评审"
    assert confirmed.metadata["candidate_extraction_id"] == extraction.extraction_id
    assert confirmed.metadata["candidate_temp_id"] == candidate.temp_id
    assert confirmed.metadata["candidate_confidence"] == candidate.confidence
    assert confirmed.metadata["candidate_reasoning"] == candidate.reasoning
    assert confirmed.metadata["user_note"] == "带会议材料"
    assert len(confirmed.reminders) == 1
    assert len(repository.list_items()) == 1
    assert len(item_outbox(repository)) == 1

    repository.close()
    reopened = SQLiteRepository(database_path)
    restarted_service, _ = build_services(reopened)
    restarted_replay = restarted_service.confirm(
        extraction_id=extraction.extraction_id,
        candidate=candidate,
        edit=edit,
        idempotency_key="confirm-candidate",
    )
    assert restarted_replay == confirmed
    assert len(reopened.list_items()) == 1
    assert len(item_outbox(reopened)) == 1
    reopened.close()


def test_confirmation_rejects_tampering_and_a_second_decision(tmp_path):
    repository = SQLiteRepository(tmp_path / "candidate.sqlite3")
    candidate_service, _ = build_services(repository)
    extraction = candidate_service.extract(
        "明天下午3点开会",
        timezone_name="Asia/Shanghai",
        now=datetime(2026, 8, 11, 10, 0, tzinfo=timezone.utc),
    )
    candidate = extraction.candidates[0]
    tampered_data = candidate.to_dict()
    tampered_data["title"] = "客户端改写的候选"

    with pytest.raises(InvalidCommandError, match="differs from the persisted"):
        candidate_service.confirm(
            extraction_id=extraction.extraction_id,
            candidate=CandidateItem.from_dict(tampered_data),
            edit=CandidateEditCommand(collection_id="collection_local"),
            idempotency_key="tampered",
        )

    original_edit = CandidateEditCommand(
        collection_id="collection_local",
        values={"title": "第一次确认"},
    )
    candidate_service.confirm(
        extraction_id=extraction.extraction_id,
        candidate=candidate,
        edit=original_edit,
        idempotency_key="first-decision",
    )

    with pytest.raises(CandidateDecisionConflictError):
        candidate_service.confirm(
            extraction_id=extraction.extraction_id,
            candidate=candidate,
            edit=CandidateEditCommand(
                collection_id="collection_local",
                values={"title": "不同的第二次确认"},
            ),
            idempotency_key="second-decision",
        )

    assert len(repository.list_items()) == 1
    assert len(item_outbox(repository)) == 1
    repository.close()


def test_rejection_is_idempotent_and_never_creates_an_item(tmp_path):
    repository = SQLiteRepository(tmp_path / "candidate.sqlite3")
    candidate_service, _ = build_services(repository)
    extraction = candidate_service.extract(
        "周五前交设计稿",
        timezone_name="Asia/Shanghai",
        now=datetime(2026, 8, 11, 10, 0, tzinfo=timezone.utc),
    )

    rejected = candidate_service.reject_extraction(
        extraction.extraction_id, reason="不需要"
    )
    replayed = candidate_service.reject_extraction(
        extraction.extraction_id, reason="后来的原因不会覆盖审计记录"
    )

    assert replayed == rejected
    assert rejected.rejection_reason == "不需要"
    assert repository.list_items() == []
    assert item_outbox(repository) == []

    with pytest.raises(ExtractionRejectedError):
        candidate_service.confirm(
            extraction_id=extraction.extraction_id,
            candidate=extraction.candidates[0],
            edit=CandidateEditCommand(collection_id="collection_local"),
            idempotency_key="confirm-rejected",
        )
    repository.close()


def test_candidate_api_extract_edit_confirm_and_reject(tmp_path):
    settings = Settings.model_validate(
        {
            "storage": {"sqlite_path": str(tmp_path / "api.sqlite3")},
            "app": {"instance_name": "candidate-api-test"},
        }
    )

    with TestClient(create_app(settings)) as client:
        extracted = client.post(
            "/v1/assistant/extract",
            json={
                "text": "明天下午3点开会",
                "timezone": "Asia/Shanghai",
                "now": "2026-08-11T10:00:00+08:00",
            },
        )
        assert extracted.status_code == 200
        preview = extracted.json()
        assert preview["candidates"][0]["start_at"] == "2026-08-12T15:00:00+08:00"

        confirmation_body = {
            "extraction_id": preview["extraction_id"],
            "candidate": preview["candidates"][0],
            "edit": {
                "collection_id": "collection_local",
                "title": "API 确认会议",
            },
        }
        confirmed = client.post(
            "/v1/items/confirm-candidate",
            headers={"Idempotency-Key": "api-confirm"},
            json=confirmation_body,
        )
        assert confirmed.status_code == 201
        item = confirmed.json()
        assert item["source"] == "ai"
        assert item["title"] == "API 确认会议"
        assert client.get(f"/v1/items/{item['id']}").json() == item
        assert client.get("/v1/items").json()["data"] == [item]

        rejected_preview = client.post(
            "/v1/assistant/extract",
            json={
                "text": "后天上午9点复盘",
                "timezone": "Asia/Shanghai",
                "now": "2026-08-11T10:00:00+08:00",
            },
        ).json()
        rejected = client.post(
            f"/v1/assistant/extractions/{rejected_preview['extraction_id']}/reject",
            json={"reason": "取消"},
        )
        assert rejected.status_code == 200
        assert rejected.json()["rejection_reason"] == "取消"

        conflict = client.post(
            "/v1/items/confirm-candidate",
            headers={"Idempotency-Key": "api-rejected-confirm"},
            json={
                "extraction_id": rejected_preview["extraction_id"],
                "candidate": rejected_preview["candidates"][0],
                "edit": {"collection_id": "collection_local"},
            },
        )
        assert conflict.status_code == 409
        assert conflict.json()["error"]["code"] == "candidate_rejected"

        missing = client.get("/v1/assistant/extractions/extract_missing")
        assert missing.status_code == 404
        assert missing.json()["error"]["code"] == "not_found"
