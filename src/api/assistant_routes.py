"""Versioned Candidate extraction and rejection routes."""

from fastapi import APIRouter, Request

from src.application import CandidateService
from src.storage import CandidateExtractionRecord

from .candidate_schemas import (
    ExtractRequest,
    ExtractionResponse,
    RejectExtractionRequest,
)


router = APIRouter(prefix="/v1/assistant", tags=["assistant"])


def get_candidate_service(request: Request) -> CandidateService:
    return request.app.state.runtime.candidate_service()


def extraction_response(record: CandidateExtractionRecord) -> ExtractionResponse:
    return ExtractionResponse(
        extraction_id=record.extraction_id,
        parser_id=record.parser_id,
        source_text=record.source_text,
        candidates=[candidate.to_dict() for candidate in record.candidates],
        warnings=record.warnings,
        created_at=record.created_at,
        rejected_at=record.rejected_at,
        rejection_reason=record.rejection_reason,
    )


@router.post("/extract", response_model=ExtractionResponse)
def extract_candidates(request: Request, body: ExtractRequest):
    timezone_name = body.timezone or request.app.state.settings.app.timezone
    record = get_candidate_service(request).extract(
        body.text,
        timezone_name=timezone_name,
        now=body.now,
        parser_id=body.parser,
    )
    return extraction_response(record)


@router.get("/extractions/{extraction_id}", response_model=ExtractionResponse)
def get_extraction(request: Request, extraction_id: str):
    return extraction_response(
        get_candidate_service(request).get_extraction(extraction_id)
    )


@router.post(
    "/extractions/{extraction_id}/reject",
    response_model=ExtractionResponse,
)
def reject_extraction(
    request: Request,
    extraction_id: str,
    body: RejectExtractionRequest,
):
    return extraction_response(
        get_candidate_service(request).reject_extraction(
            extraction_id, reason=body.reason
        )
    )
