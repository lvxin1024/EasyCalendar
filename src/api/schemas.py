"""Pydantic schemas for API request/response validation."""

from datetime import datetime
from typing import Optional, List
from pydantic import BaseModel, Field


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
    attendees: List[str] = []
    timezone: str = "Asia/Shanghai"


class ParseTextRequest(BaseModel):
    """Schema for parsing text to calendar events."""

    text: str = Field(..., description="Text to parse")
    reference_date: Optional[datetime] = Field(None, description="Reference date for parsing")


class ParseTextResponse(BaseModel):
    """Schema for parsed text response."""

    events: List[CalendarEventResponse]
    confidence: float = Field(..., description="Parsing confidence score")
    original_text: str


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
