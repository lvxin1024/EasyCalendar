"""Versioned HTTP adapters for read-only Collections and subscriptions."""

from __future__ import annotations

from typing import Annotated, Optional

from fastapi import APIRouter, Header, Query, Request, status

from src.application import InvalidCommandError, SubscriptionService

from .subscription_schemas import (
    CollectionCreateRequest,
    CollectionUpdateRequest,
    SubscriptionCreateRequest,
    SubscriptionUpdateRequest,
)


collection_router = APIRouter(prefix="/v1/collections", tags=["collections"])
subscription_router = APIRouter(prefix="/v1/subscriptions", tags=["subscriptions"])


def get_subscription_service(request: Request) -> SubscriptionService:
    return request.app.state.runtime.subscription_service()


def _expected_version(query_version: Optional[int], if_match: Optional[str]) -> int:
    if query_version is not None:
        return query_version
    if if_match is None:
        raise InvalidCommandError("expected_version or If-Match is required")
    normalized = if_match.strip().removeprefix("W/").strip('"')
    try:
        version = int(normalized)
    except ValueError as error:
        raise InvalidCommandError("If-Match must contain a resource version") from error
    if version < 1:
        raise InvalidCommandError("If-Match version must be at least 1")
    return version


@collection_router.post("", status_code=status.HTTP_201_CREATED)
def create_collection(
    request: Request,
    body: CollectionCreateRequest,
    idempotency_key: Annotated[str, Header(alias="Idempotency-Key", min_length=1, max_length=200)],
):
    return get_subscription_service(request).create_collection(
        body.to_command(), idempotency_key=idempotency_key
    ).to_dict()


@collection_router.get("")
def list_collections(request: Request, include_deleted: bool = False):
    return {
        "data": [value.to_dict() for value in get_subscription_service(request).list_collections(include_deleted=include_deleted)],
        "next_cursor": None,
        "has_more": False,
    }


@collection_router.get("/{collection_id}")
def get_collection(request: Request, collection_id: str, include_deleted: bool = False):
    return get_subscription_service(request).get_collection(collection_id, include_deleted=include_deleted).to_dict()


@collection_router.patch("/{collection_id}")
def update_collection(request: Request, collection_id: str, body: CollectionUpdateRequest):
    return get_subscription_service(request).update_collection(collection_id, body.to_command()).to_dict()


@collection_router.delete("/{collection_id}")
def delete_collection(
    request: Request,
    collection_id: str,
    expected_version: Optional[int] = Query(default=None, ge=1),
    if_match: Optional[str] = Header(default=None, alias="If-Match"),
):
    return get_subscription_service(request).delete_collection(
        collection_id, expected_version=_expected_version(expected_version, if_match)
    ).to_dict()


@subscription_router.post("", status_code=status.HTTP_201_CREATED)
def create_subscription(
    request: Request,
    body: SubscriptionCreateRequest,
    idempotency_key: Annotated[str, Header(alias="Idempotency-Key", min_length=1, max_length=200)],
):
    return get_subscription_service(request).create_subscription(
        body.to_command(), idempotency_key=idempotency_key
    ).to_dict()


@subscription_router.get("")
def list_subscriptions(request: Request, include_deleted: bool = False):
    return {
        "data": [value.to_dict() for value in get_subscription_service(request).list_subscriptions(include_deleted=include_deleted)],
        "next_cursor": None,
        "has_more": False,
    }


@subscription_router.get("/{subscription_id}")
def get_subscription(request: Request, subscription_id: str, include_deleted: bool = False):
    return get_subscription_service(request).get_subscription(subscription_id, include_deleted=include_deleted).to_dict()


@subscription_router.patch("/{subscription_id}")
def update_subscription(request: Request, subscription_id: str, body: SubscriptionUpdateRequest):
    return get_subscription_service(request).update_subscription(subscription_id, body.to_command()).to_dict()


@subscription_router.delete("/{subscription_id}")
def delete_subscription(
    request: Request,
    subscription_id: str,
    expected_version: Optional[int] = Query(default=None, ge=1),
    if_match: Optional[str] = Header(default=None, alias="If-Match"),
):
    return get_subscription_service(request).delete_subscription(
        subscription_id, expected_version=_expected_version(expected_version, if_match)
    ).to_dict()
