"""Versioned HTTP adapter for formal Item use cases."""

from __future__ import annotations

from datetime import datetime
from typing import Annotated, Optional

from fastapi import APIRouter, Header, Query, Request, status

from src.application import InvalidCommandError, ItemService
from src.domain import ItemStatus, ItemType

from .item_schemas import (
    ItemCreateRequest,
    ItemListResponse,
    ItemUpdateRequest,
    VersionCommandRequest,
)
from .candidate_schemas import ConfirmCandidateRequest


router = APIRouter(prefix="/v1/items", tags=["items"])


def get_item_service(request: Request) -> ItemService:
    return request.app.state.runtime.item_service()


def _expected_version(
    query_version: Optional[int], if_match: Optional[str]
) -> int:
    if query_version is not None:
        return query_version
    if if_match is None:
        raise InvalidCommandError("expected_version or If-Match is required")
    normalized = if_match.strip().removeprefix("W/").strip('"')
    try:
        version = int(normalized)
    except ValueError as error:
        raise InvalidCommandError("If-Match must contain an Item version") from error
    if version < 1:
        raise InvalidCommandError("If-Match version must be at least 1")
    return version


@router.post("", status_code=status.HTTP_201_CREATED)
def create_item(
    request: Request,
    body: ItemCreateRequest,
    idempotency_key: Annotated[
        str, Header(alias="Idempotency-Key", min_length=1, max_length=200)
    ],
):
    item = get_item_service(request).create_item(
        body.to_command(), idempotency_key=idempotency_key
    )
    return item.to_dict()


@router.get("", response_model=ItemListResponse)
def list_items(
    request: Request,
    collection_id: Optional[str] = None,
    item_type: Optional[ItemType] = Query(default=None, alias="type"),
    item_status: Optional[ItemStatus] = Query(default=None, alias="status"),
    from_at: Optional[datetime] = Query(default=None, alias="from"),
    to_at: Optional[datetime] = Query(default=None, alias="to"),
    include_deleted: bool = False,
    cursor: Optional[str] = None,
    limit: int = Query(default=50, ge=1, le=200),
):
    page = get_item_service(request).list_items(
        collection_id=collection_id,
        item_type=item_type,
        status=item_status,
        from_at=from_at,
        to_at=to_at,
        include_deleted=include_deleted,
        cursor=cursor,
        limit=limit,
    )
    return ItemListResponse(
        data=[item.to_dict() for item in page.items],
        next_cursor=page.next_cursor,
        has_more=page.has_more,
    )


@router.post("/confirm-candidate", status_code=status.HTTP_201_CREATED)
def confirm_candidate(
    request: Request,
    body: ConfirmCandidateRequest,
    idempotency_key: Annotated[
        str, Header(alias="Idempotency-Key", min_length=1, max_length=200)
    ],
):
    item = request.app.state.runtime.candidate_service().confirm(
        extraction_id=body.extraction_id,
        candidate=body.candidate.to_domain(),
        edit=body.edit.to_command(),
        idempotency_key=idempotency_key,
    )
    return item.to_dict()


@router.get("/{item_id}")
def get_item(request: Request, item_id: str, include_deleted: bool = False):
    return get_item_service(request).get_item(
        item_id, include_deleted=include_deleted
    ).to_dict()


@router.patch("/{item_id}")
def update_item(request: Request, item_id: str, body: ItemUpdateRequest):
    return get_item_service(request).update_item(
        item_id, body.to_command()
    ).to_dict()


@router.delete("/{item_id}")
def delete_item(
    request: Request,
    item_id: str,
    expected_version: Optional[int] = Query(default=None, ge=1),
    if_match: Optional[str] = Header(default=None, alias="If-Match"),
):
    return get_item_service(request).delete_item(
        item_id,
        expected_version=_expected_version(expected_version, if_match),
    ).to_dict()


@router.post("/{item_id}/restore")
def restore_item(request: Request, item_id: str, body: VersionCommandRequest):
    return get_item_service(request).restore_item(
        item_id, expected_version=body.expected_version
    ).to_dict()


@router.post("/{item_id}/complete")
def complete_task(
    request: Request,
    item_id: str,
    body: VersionCommandRequest,
    idempotency_key: Annotated[
        str, Header(alias="Idempotency-Key", min_length=1, max_length=200)
    ],
):
    return get_item_service(request).complete_task(
        item_id,
        expected_version=body.expected_version,
        idempotency_key=idempotency_key,
    ).to_dict()
