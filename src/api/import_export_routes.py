"""Versioned HTTP adapter for backup and calendar transfers."""

from __future__ import annotations

from typing import Annotated, Literal, Optional

from fastapi import APIRouter, Header, Query, Request, Response

from src.application.import_export_service import ImportExportService

from .import_export_schemas import ImportRequest


router = APIRouter(prefix="/v1", tags=["transfer"])


def get_transfer_service(request: Request) -> ImportExportService:
    return request.app.state.runtime.import_export_service()


@router.post("/import")
def import_content(
    request: Request,
    body: ImportRequest,
    idempotency_key: Annotated[
        Optional[str], Header(alias="Idempotency-Key", max_length=200)
    ] = None,
):
    return get_transfer_service(request).import_content(
        format=body.format,
        mode=body.mode,
        strategy=body.strategy,
        content=body.content,
        collection_id=body.collection_id,
        idempotency_key=idempotency_key,
    ).to_dict()


@router.get("/export")
def export_content(
    request: Request,
    format: Literal["json", "ics"] = Query(default="json"),
    scope: Literal["all", "collection"] = Query(default="all"),
    collection_id: Optional[str] = None,
):
    service = get_transfer_service(request)
    selected_collection = collection_id if scope == "collection" else None
    if scope == "collection" and not collection_id:
        from src.application import InvalidCommandError

        raise InvalidCommandError("collection_id is required for collection scope")
    if format == "json":
        content = service.export_json(collection_id=selected_collection)
        media_type = "application/json"
        filename = "easycalendar-backup.json"
    else:
        content = service.export_ics(collection_id=selected_collection)
        media_type = "text/calendar"
        filename = "easycalendar-events.ics"
    return Response(
        content=content,
        media_type=media_type,
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )
