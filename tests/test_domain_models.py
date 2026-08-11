"""Tests for the candidate and formal item domain models."""

from datetime import datetime, timezone

import pytest

from src.domain.models import (
    CandidateItem,
    ItemSource,
    ItemStatus,
    ItemType,
    ReminderMode,
    ReminderSuggestion,
)
from src.parser.rule_parser import RuleParser


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

    confirmed_at = datetime(2026, 8, 11, 8, 0, tzinfo=timezone.utc)
    item = candidate.to_item(
        collection_id="local",
        item_id="item_001",
        source=ItemSource.AI,
        now=confirmed_at,
    )

    assert item.id == "item_001"
    assert item.type is ItemType.TASK
    assert item.status is ItemStatus.TODO
    assert item.source is ItemSource.AI
    assert item.due_at == candidate.due_at
    assert item.created_at == confirmed_at
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
    assert result.candidates[1].source_text_span.start > result.candidates[0].source_text_span.end
    assert len(result.events) == 2
