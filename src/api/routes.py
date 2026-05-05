"""API routes for calendar operations."""

from typing import List, Optional
from datetime import datetime
from fastapi import APIRouter, HTTPException, Query
from fastapi.responses import JSONResponse

from .schemas import (
    ParseTextRequest,
    ParseTextResponse,
    CalendarEventCreate,
    CalendarEventResponse,
    SyncRequest,
    SyncResponse,
    ExportRequest,
    ExportResponse,
)
from ..parser.rule_parser import RuleParser
from ..parser.models import CalendarEvent
from ..calendar_client.google_calendar import GoogleCalendarClient
from ..calendar_client.outlook_calendar import OutlookCalendarClient
from ..calendar_client.ical_client import ICalClient


router = APIRouter(prefix="/api/v1", tags=["calendar"])

parser = RuleParser()


def get_calendar_client(calendar_type: str):
    """Get calendar client by type."""
    clients = {
        "google": GoogleCalendarClient,
        "outlook": OutlookCalendarClient,
        "ical": ICalClient,
    }

    client_class = clients.get(calendar_type.lower())
    if not client_class:
        raise HTTPException(
            status_code=400,
            detail=f"Invalid calendar type: {calendar_type}. Supported: {list(clients.keys())}",
        )

    try:
        return client_class()
    except Exception as error:
        raise HTTPException(status_code=500, detail=f"Failed to initialize {calendar_type} client: {str(error)}")


def event_to_response(event: CalendarEvent, event_id: str) -> CalendarEventResponse:
    """Convert CalendarEvent to response schema."""
    return CalendarEventResponse(
        id=event_id or event.source_text,
        title=event.title,
        start_time=event.start_time,
        end_time=event.end_time,
        description=event.description,
        location=event.location,
        attendees=event.attendees,
        timezone=event.timezone,
    )


@router.post("/parse", response_model=ParseTextResponse)
async def parse_text(request: ParseTextRequest):
    """Parse text into calendar events."""
    try:
        result = parser.parse(request.text)

        events = []
        for event in result.events:
            events.append(
                CalendarEventResponse(
                    id=event.source_text or f"parsed_{len(events)}",
                    title=event.title,
                    start_time=event.start_time,
                    end_time=event.end_time,
                    description=event.description,
                    location=event.location,
                    attendees=event.attendees,
                    timezone=event.timezone,
                )
            )

        return ParseTextResponse(
            events=events,
            confidence=result.confidence,
            original_text=result.original_text,
        )

    except Exception as error:
        raise HTTPException(status_code=500, detail=f"Parsing error: {str(error)}")


@router.post("/events", response_model=CalendarEventResponse)
async def create_event(request: CalendarEventCreate):
    """Create a new calendar event."""
    try:
        event = CalendarEvent(
            title=request.title,
            start_time=request.start_time,
            end_time=request.end_time,
            description=request.description,
            location=request.location,
            attendees=request.attendees,
            timezone=request.timezone,
        )

        return CalendarEventResponse(
            id="manual_created",
            **request.model_dump(),
        )

    except Exception as error:
        raise HTTPException(status_code=500, detail=f"Event creation error: {str(error)}")


@router.get("/events", response_model=List[CalendarEventResponse])
async def list_events(
    calendar_type: str = Query(..., description="Calendar type (google, outlook, ical)"),
    start_date: Optional[datetime] = Query(None, description="Start date"),
    end_date: Optional[datetime] = Query(None, description="End date"),
    max_results: int = Query(100, ge=1, le=1000, description="Maximum number of events"),
):
    """List calendar events."""
    try:
        client = get_calendar_client(calendar_type)
        events = client.list_events(start_date, end_date, max_results)

        return [
            event_to_response(event, event.source_text) for event in events
        ]

    except HTTPException:
        raise
    except Exception as error:
        raise HTTPException(status_code=500, detail=f"List events error: {str(error)}")


@router.post("/sync", response_model=SyncResponse)
async def sync_events(request: SyncRequest):
    """Sync events to specified calendar."""
    try:
        client = get_calendar_client(request.calendar_type)

        synced_ids = []
        errors = []

        for event_data in request.events:
            event = CalendarEvent(
                title=event_data.title,
                start_time=event_data.start_time,
                end_time=event_data.end_time,
                description=event_data.description,
                location=event_data.location,
                attendees=event_data.attendees,
                timezone=event_data.timezone,
            )

            event_id = client.create_event(event)
            if event_id:
                synced_ids.append(event_id)
            else:
                errors.append(f"Failed to sync: {event.title}")

        return SyncResponse(
            success=len(errors) == 0,
            synced_count=len(synced_ids),
            event_ids=synced_ids,
            errors=errors,
        )

    except HTTPException:
        raise
    except Exception as error:
        raise HTTPException(status_code=500, detail=f"Sync error: {str(error)}")


@router.post("/export", response_model=ExportResponse)
async def export_calendar(request: ExportRequest):
    """Export calendar to specified format."""
    try:
        client = get_calendar_client(request.calendar_type)

        if request.format == "ical":
            content = client.export_calendar()
            filename = f"calendar_export_{datetime.now().strftime('%Y%m%d_%H%M%S')}.ics"
        else:
            raise HTTPException(status_code=400, detail=f"Unsupported format: {request.format}")

        return ExportResponse(
            format=request.format,
            content=content,
            filename=filename,
        )

    except HTTPException:
        raise
    except Exception as error:
        raise HTTPException(status_code=500, detail=f"Export error: {str(error)}")


@router.get("/health")
async def health_check():
    """Health check endpoint."""
    return {"status": "healthy", "service": "text2calendar"}
