"""Strict schemas for Candidate extraction and confirmation."""

from __future__ import annotations

from datetime import datetime
from typing import Any, Dict, List, Optional

from pydantic import Field

from src.application import CandidateEditCommand
from src.domain import (
    CandidateItem,
    ItemStatus,
    ItemType,
    RecurrenceRule,
    ReminderMode,
    ReminderSuggestion,
    SourceTextSpan,
)

from .item_schemas import RecurrenceInput, ReminderInput, StrictApiModel


class SourceTextSpanInput(StrictApiModel):
    start: int = Field(ge=0)
    end: int = Field(ge=0)

    def to_domain(self) -> SourceTextSpan:
        return SourceTextSpan(**self.model_dump())


class ReminderSuggestionInput(StrictApiModel):
    mode: ReminderMode = ReminderMode.RELATIVE
    minutes_before: Optional[int] = None
    remind_at: Optional[datetime] = None
    enabled: bool = True
    reason: Optional[str] = None

    def to_domain(self) -> ReminderSuggestion:
        return ReminderSuggestion(**self.model_dump())


class CandidateInput(StrictApiModel):
    temp_id: str
    type: ItemType
    title: str
    body: Optional[str] = None
    start_at: Optional[datetime] = None
    end_at: Optional[datetime] = None
    due_at: Optional[datetime] = None
    timezone: Optional[str] = "Asia/Shanghai"
    location: Optional[str] = None
    attendees: List[str] = Field(default_factory=list)
    reminders: List[ReminderSuggestionInput] = Field(default_factory=list)
    confidence: float = Field(ge=0.0, le=1.0)
    reasoning: Optional[str] = None
    source_text_span: Optional[SourceTextSpanInput] = None
    priority: Optional[int] = Field(default=None, ge=0, le=3)
    recurrence: Optional[RecurrenceInput] = None

    def to_domain(self) -> CandidateItem:
        values = self.model_dump(
            exclude={"reminders", "source_text_span", "recurrence"}
        )
        return CandidateItem(
            **values,
            reminders=[reminder.to_domain() for reminder in self.reminders],
            source_text_span=(
                self.source_text_span.to_domain()
                if self.source_text_span
                else None
            ),
            recurrence=self.recurrence.to_domain() if self.recurrence else None,
        )


class CandidateEditInput(StrictApiModel):
    collection_id: str
    type: Optional[ItemType] = None
    title: Optional[str] = None
    body: Optional[str] = None
    start_at: Optional[datetime] = None
    end_at: Optional[datetime] = None
    due_at: Optional[datetime] = None
    timezone: Optional[str] = None
    location: Optional[str] = None
    attendees: Optional[List[str]] = None
    reminders: Optional[List[ReminderInput]] = None
    priority: Optional[int] = Field(default=None, ge=0, le=3)
    recurrence: Optional[RecurrenceInput] = None
    all_day: Optional[bool] = None
    status: Optional[ItemStatus] = None
    tags: Optional[List[str]] = None
    metadata: Optional[Dict[str, Any]] = None

    def to_command(self) -> CandidateEditCommand:
        values: Dict[str, Any] = {}
        for field_name in self.model_fields_set - {"collection_id"}:
            value = getattr(self, field_name)
            if field_name == "recurrence" and value is not None:
                value = value.to_domain()
            elif field_name == "reminders" and value is not None:
                value = [reminder.to_draft() for reminder in value]
            values[field_name] = value
        return CandidateEditCommand(
            collection_id=self.collection_id,
            values=values,
        )


class ConfirmCandidateRequest(StrictApiModel):
    extraction_id: str
    candidate: CandidateInput
    edit: CandidateEditInput


class ExtractRequest(StrictApiModel):
    text: str
    timezone: Optional[str] = None
    now: Optional[datetime] = None
    parser: str = "auto"


class RejectExtractionRequest(StrictApiModel):
    reason: Optional[str] = None


class ExtractionResponse(StrictApiModel):
    extraction_id: str
    parser_id: str
    source_text: str
    candidates: List[Dict[str, Any]]
    warnings: List[str]
    created_at: datetime
    rejected_at: Optional[datetime]
    rejection_reason: Optional[str]
