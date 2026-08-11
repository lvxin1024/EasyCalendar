"""API module for REST endpoints."""

from .routes import router
from .schemas import (
    CandidateItemResponse,
    ReminderSuggestionResponse,
    SourceTextSpanResponse,
    CalendarEventCreate,
    CalendarEventResponse,
    ParseTextRequest,
    ParseTextResponse,
    SyncRequest,
    SyncResponse,
    ExportRequest,
    ExportResponse,
)

__all__ = [
    "router",
    "CandidateItemResponse",
    "ReminderSuggestionResponse",
    "SourceTextSpanResponse",
    "CalendarEventCreate",
    "CalendarEventResponse",
    "ParseTextRequest",
    "ParseTextResponse",
    "SyncRequest",
    "SyncResponse",
    "ExportRequest",
    "ExportResponse",
]
