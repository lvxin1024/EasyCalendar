"""Candidate extraction, preview, confirmation, and rejection use cases."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Callable, List, Optional, Protocol
from uuid import uuid4
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from src.domain import CandidateItem, Item
from src.storage import CandidateExtractionRecord, EntityNotFoundError

from .errors import ExtractionNotFoundError, InvalidCommandError
from .item_service import CandidateEditCommand, ItemService
from .ports import CandidateRepositoryPort


@dataclass(frozen=True)
class CandidateParseResult:
    parser_id: str
    candidates: List[CandidateItem]
    warnings: List[str]


class CandidateParserPort(Protocol):
    def extract(
        self, text: str, *, now: datetime, timezone_name: str
    ) -> CandidateParseResult: ...


def _default_id_factory(prefix: str) -> str:
    return f"{prefix}_{uuid4().hex}"


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


class CandidateService:
    def __init__(
        self,
        repository: CandidateRepositoryPort,
        item_service: ItemService,
        parser: CandidateParserPort,
        *,
        max_input_chars: int,
        clock: Callable[[], datetime] = _utc_now,
        id_factory: Callable[[str], str] = _default_id_factory,
    ):
        if type(max_input_chars) is not int or max_input_chars < 1:
            raise ValueError("max_input_chars must be positive")
        self.repository = repository
        self.item_service = item_service
        self.parser = parser
        self.max_input_chars = max_input_chars
        self._clock = clock
        self._id_factory = id_factory

    def extract(
        self,
        text: str,
        *,
        timezone_name: str,
        now: Optional[datetime] = None,
        parser_id: str = "auto",
    ) -> CandidateExtractionRecord:
        if not isinstance(text, str) or not text.strip():
            raise InvalidCommandError("text cannot be empty")
        if len(text) > self.max_input_chars:
            raise InvalidCommandError(
                f"text cannot exceed {self.max_input_chars} characters"
            )
        if parser_id not in {"auto", "rules", "rules.zh_cn"}:
            raise InvalidCommandError(f"Unsupported parser: {parser_id}")
        try:
            zone = ZoneInfo(timezone_name)
        except (TypeError, ZoneInfoNotFoundError) as error:
            raise InvalidCommandError(
                f"Unknown extraction timezone: {timezone_name}"
            ) from error
        reference = now or self._now()
        if reference.tzinfo is None or reference.utcoffset() is None:
            raise InvalidCommandError("now must include a timezone")
        reference = reference.astimezone(zone)
        parsed = self.parser.extract(
            text, now=reference, timezone_name=timezone_name
        )
        record = CandidateExtractionRecord(
            extraction_id=self._id_factory("extract"),
            parser_id=parsed.parser_id,
            source_text=text,
            candidates=parsed.candidates,
            warnings=parsed.warnings,
            created_at=self._now(),
        )
        return self.repository.create_candidate_extraction(record)

    def get_extraction(self, extraction_id: str) -> CandidateExtractionRecord:
        record = self.repository.get_candidate_extraction(extraction_id)
        if record is None:
            raise ExtractionNotFoundError(
                f"Candidate extraction {extraction_id!r} was not found"
            )
        return record

    def reject_extraction(
        self, extraction_id: str, *, reason: Optional[str] = None
    ) -> CandidateExtractionRecord:
        if reason is not None:
            reason = reason.strip() or None
        try:
            return self.repository.reject_candidate_extraction(
                extraction_id,
                rejected_at=self._now(),
                reason=reason,
            )
        except EntityNotFoundError as error:
            raise ExtractionNotFoundError(
                f"Candidate extraction {extraction_id!r} was not found"
            ) from error

    def confirm(
        self,
        *,
        extraction_id: str,
        candidate: CandidateItem,
        edit: CandidateEditCommand,
        idempotency_key: str,
    ) -> Item:
        return self.item_service.confirm_candidate(
            extraction_id=extraction_id,
            candidate=candidate,
            edit=edit,
            idempotency_key=idempotency_key,
        )

    def _now(self) -> datetime:
        timestamp = self._clock()
        if timestamp.tzinfo is None or timestamp.utcoffset() is None:
            raise ValueError(
                "CandidateService clock must return a timezone-aware datetime"
            )
        return timestamp
