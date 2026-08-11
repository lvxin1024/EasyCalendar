"""Strict request and response schemas for the formal Item API."""

from __future__ import annotations

from datetime import datetime
from typing import Any, Dict, List, Optional

from pydantic import BaseModel, ConfigDict, Field

from src.application import CreateItemCommand, ReminderDraft, UpdateItemCommand
from src.domain import (
    ItemSource,
    ItemStatus,
    ItemType,
    RecurrenceRule,
    ReminderMode,
)


class StrictApiModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class RecurrenceInput(StrictApiModel):
    rrule: str
    exdates: List[str] = Field(default_factory=list)
    rdates: List[str] = Field(default_factory=list)

    def to_domain(self) -> RecurrenceRule:
        return RecurrenceRule(**self.model_dump())


class ReminderInput(StrictApiModel):
    id: Optional[str] = None
    mode: ReminderMode
    minutes_before: Optional[int] = None
    remind_at: Optional[datetime] = None
    enabled: bool = True

    def to_draft(self) -> ReminderDraft:
        return ReminderDraft(**self.model_dump())


class ItemCreateRequest(StrictApiModel):
    id: Optional[str] = None
    collection_id: str
    type: ItemType
    title: str
    body: Optional[str] = None
    start_at: Optional[datetime] = None
    end_at: Optional[datetime] = None
    due_at: Optional[datetime] = None
    timezone: Optional[str] = "Asia/Shanghai"
    all_day: bool = False
    location: Optional[str] = None
    status: ItemStatus = ItemStatus.TODO
    priority: Optional[int] = Field(default=None, ge=0, le=3)
    recurrence: Optional[RecurrenceInput] = None
    reminders: List[ReminderInput] = Field(default_factory=list)
    tags: List[str] = Field(default_factory=list)
    source: ItemSource = ItemSource.LOCAL
    metadata: Dict[str, Any] = Field(default_factory=dict)

    def to_command(self) -> CreateItemCommand:
        values = self.model_dump(exclude={"recurrence", "reminders"})
        return CreateItemCommand(
            **values,
            recurrence=self.recurrence.to_domain() if self.recurrence else None,
            reminders=[reminder.to_draft() for reminder in self.reminders],
        )


class ItemPatch(StrictApiModel):
    collection_id: Optional[str] = None
    type: Optional[ItemType] = None
    title: Optional[str] = None
    body: Optional[str] = None
    start_at: Optional[datetime] = None
    end_at: Optional[datetime] = None
    due_at: Optional[datetime] = None
    timezone: Optional[str] = None
    all_day: Optional[bool] = None
    location: Optional[str] = None
    status: Optional[ItemStatus] = None
    priority: Optional[int] = Field(default=None, ge=0, le=3)
    recurrence: Optional[RecurrenceInput] = None
    reminders: Optional[List[ReminderInput]] = None
    tags: Optional[List[str]] = None
    metadata: Optional[Dict[str, Any]] = None

    def command_values(self) -> Dict[str, Any]:
        values: Dict[str, Any] = {}
        for field_name in self.model_fields_set:
            value = getattr(self, field_name)
            if field_name == "recurrence" and value is not None:
                value = value.to_domain()
            elif field_name == "reminders" and value is not None:
                value = [reminder.to_draft() for reminder in value]
            values[field_name] = value
        return values


class ItemUpdateRequest(StrictApiModel):
    expected_version: int = Field(ge=1)
    patch: ItemPatch

    def to_command(self) -> UpdateItemCommand:
        return UpdateItemCommand(
            expected_version=self.expected_version,
            values=self.patch.command_values(),
        )


class VersionCommandRequest(StrictApiModel):
    expected_version: int = Field(ge=1)


class ItemListResponse(StrictApiModel):
    data: List[Dict[str, Any]]
    next_cursor: Optional[str]
    has_more: bool
