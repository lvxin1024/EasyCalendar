"""Strict request schemas for Collection and Subscription APIs."""

from __future__ import annotations

from typing import Any, Dict, Optional

from pydantic import Field

from src.application import (
    CreateCollectionCommand,
    CreateSubscriptionCommand,
    UpdateCollectionCommand,
    UpdateSubscriptionCommand,
)
from src.domain import CollectionKind, SubscriptionType

from .item_schemas import StrictApiModel


class CollectionCreateRequest(StrictApiModel):
    id: Optional[str] = None
    name: str
    kind: CollectionKind = CollectionKind.LOCAL
    color: Optional[str] = None
    metadata: Dict[str, Any] = Field(default_factory=dict)

    def to_command(self) -> CreateCollectionCommand:
        return CreateCollectionCommand(**self.model_dump())


class CollectionPatch(StrictApiModel):
    name: Optional[str] = None
    color: Optional[str] = None
    metadata: Optional[Dict[str, Any]] = None

    def command_values(self) -> Dict[str, Any]:
        return {name: getattr(self, name) for name in self.model_fields_set}


class CollectionUpdateRequest(StrictApiModel):
    expected_version: int = Field(ge=1)
    patch: CollectionPatch

    def to_command(self) -> UpdateCollectionCommand:
        return UpdateCollectionCommand(
            expected_version=self.expected_version,
            values=self.patch.command_values(),
        )


class SubscriptionCreateRequest(StrictApiModel):
    id: Optional[str] = None
    type: SubscriptionType = SubscriptionType.ICS
    url: str
    title: str
    enabled: bool = True
    metadata: Dict[str, Any] = Field(default_factory=dict)

    def to_command(self) -> CreateSubscriptionCommand:
        return CreateSubscriptionCommand(**self.model_dump())


class SubscriptionPatch(StrictApiModel):
    title: Optional[str] = None
    url: Optional[str] = None
    enabled: Optional[bool] = None
    refresh_interval_minutes: Optional[int] = Field(default=None, ge=1, le=10080)
    metadata: Optional[Dict[str, Any]] = None

    def command_values(self) -> Dict[str, Any]:
        return {name: getattr(self, name) for name in self.model_fields_set}


class SubscriptionUpdateRequest(StrictApiModel):
    expected_version: int = Field(ge=1)
    patch: SubscriptionPatch

    def to_command(self) -> UpdateSubscriptionCommand:
        return UpdateSubscriptionCommand(
            expected_version=self.expected_version,
            values=self.patch.command_values(),
        )
