"""Pydantic schemas for API request/response validation."""

from datetime import datetime
from typing import Optional, List
from pydantic import BaseModel, Field


class ReminderSuggestionResponse(BaseModel):
    """A reminder suggestion that still needs user confirmation."""

    mode: str = "relative"
    minutes_before: Optional[int] = None
    remind_at: Optional[datetime] = None
    enabled: bool = True
    reason: Optional[str] = None


class SourceTextSpanResponse(BaseModel):
    """Location of a candidate in the submitted source text."""

    start: int
    end: int


class CandidateItemResponse(BaseModel):
    """API representation of an unconfirmed parsed item."""

    temp_id: str
    type: str
    title: str
    body: Optional[str] = None
    start_at: Optional[datetime] = None
    end_at: Optional[datetime] = None
    due_at: Optional[datetime] = None
    timezone: Optional[str] = "Asia/Shanghai"
    location: Optional[str] = None
    attendees: List[str] = Field(default_factory=list)
    reminders: List[ReminderSuggestionResponse] = Field(default_factory=list)
    confidence: float
    reasoning: Optional[str] = None
    source_text_span: Optional[SourceTextSpanResponse] = None
    priority: Optional[int] = None


class CalendarEventCreate(BaseModel):
    """Schema for creating a calendar event."""

    title: str = Field(..., description="Event title")
    start_time: datetime = Field(..., description="Event start time")
    end_time: datetime = Field(..., description="Event end time")
    description: Optional[str] = Field(None, description="Event description")
    location: Optional[str] = Field(None, description="Event location")
    attendees: List[str] = Field(default_factory=list, description="List of attendee emails")
    timezone: str = Field("Asia/Shanghai", description="Timezone")


class CalendarEventResponse(BaseModel):
    """Schema for calendar event response."""

    id: str = Field(..., description="Event ID")
    title: str
    start_time: datetime
    end_time: datetime
    description: Optional[str] = None
    location: Optional[str] = None
    attendees: List[str] = Field(default_factory=list)
    timezone: str = "Asia/Shanghai"


class ParseTextRequest(BaseModel):
    """Schema for parsing text to calendar events."""

    text: str = Field(..., description="Text to parse")
    reference_date: Optional[datetime] = Field(None, description="Reference date for parsing")


class ParseTextResponse(BaseModel):
    """Schema for parsed text response."""

    candidates: List[CandidateItemResponse]
    confidence: float = Field(..., description="Parsing confidence score")
    original_text: str
    events: List[CalendarEventResponse] = Field(
        default_factory=list,
        description="Deprecated compatibility view; candidates are not confirmed events.",
    )


class SyncRequest(BaseModel):
    """Schema for syncing events to calendar."""

    events: List[CalendarEventCreate] = Field(..., description="Events to sync")
    calendar_type: str = Field(..., description="Calendar type (google, outlook, ical)")


class SyncResponse(BaseModel):
    """Schema for sync response."""

    success: bool
    synced_count: int
    event_ids: List[str]
    errors: List[str] = []


class ExportRequest(BaseModel):
    """Schema for exporting calendar."""

    calendar_type: str = Field(..., description="Calendar type to export from")
    format: str = Field("ical", description="Export format (ical, json)")


class ExportResponse(BaseModel):
    """Schema for export response."""

    format: str
    content: str
    filename: str
