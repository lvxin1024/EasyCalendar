"""Strict HTTP contracts for JSON and ICS transfers."""

from typing import Literal, Optional

from pydantic import BaseModel, ConfigDict


class ImportRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    format: Literal["json", "ics"]
    mode: Literal["preview", "commit"] = "preview"
    strategy: Literal["merge", "replace"] = "merge"
    content: str
    collection_id: Optional[str] = None
