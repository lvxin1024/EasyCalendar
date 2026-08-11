"""Uniform API error envelopes for versioned endpoints."""

from __future__ import annotations

from typing import Any, Dict, Optional, Type
from uuid import uuid4

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from src.application import (
    CandidateDecisionConflictError,
    CollectionNotFoundError,
    ExtractionNotFoundError,
    ExtractionRejectedError,
    IdempotencyConflictError,
    InvalidCommandError,
    InvalidCursorError,
    ItemNotFoundError,
    ReadonlyCollectionError,
    SubscriptionNotFoundError,
)
from src.storage import (
    ConstraintViolationError,
    EntityAlreadyExistsError,
    EntityNotFoundError,
    VersionConflictError,
)


def _request_id(request: Request) -> str:
    return request.headers.get("X-Request-Id") or f"req_{uuid4().hex}"


def _response(
    request: Request,
    *,
    status_code: int,
    code: str,
    message: str,
    details: Optional[Dict[str, Any]] = None,
) -> JSONResponse:
    return JSONResponse(
        status_code=status_code,
        content={
            "error": {
                "code": code,
                "message": message,
                "details": details or {},
                "request_id": _request_id(request),
            }
        },
    )


def register_error_handlers(app: FastAPI) -> None:
    mappings: list[tuple[Type[Exception], int, str]] = [
        (ItemNotFoundError, 404, "not_found"),
        (ExtractionNotFoundError, 404, "not_found"),
        (CollectionNotFoundError, 404, "not_found"),
        (SubscriptionNotFoundError, 404, "not_found"),
        (EntityNotFoundError, 404, "not_found"),
        (ReadonlyCollectionError, 403, "readonly_collection"),
        (IdempotencyConflictError, 409, "idempotency_conflict"),
        (CandidateDecisionConflictError, 409, "candidate_decision_conflict"),
        (ExtractionRejectedError, 409, "candidate_rejected"),
        (InvalidCursorError, 400, "validation_error"),
        (InvalidCommandError, 400, "validation_error"),
        (ConstraintViolationError, 400, "validation_error"),
        (EntityAlreadyExistsError, 409, "resource_conflict"),
    ]

    for exception_type, status_code, code in mappings:
        async def handler(
            request: Request,
            error: Exception,
            status: int = status_code,
            error_code: str = code,
        ) -> JSONResponse:
            return _response(
                request,
                status_code=status,
                code=error_code,
                message=str(error),
            )

        app.add_exception_handler(exception_type, handler)

    async def version_handler(
        request: Request, error: VersionConflictError
    ) -> JSONResponse:
        return _response(
            request,
            status_code=409,
            code="version_conflict",
            message=str(error),
            details={
                "entity_type": error.entity_type,
                "entity_id": error.entity_id,
                "expected_version": error.expected,
                "actual_version": error.actual,
            },
        )

    async def validation_handler(
        request: Request, error: RequestValidationError
    ) -> JSONResponse:
        details = {
            "errors": [
                {
                    "field": ".".join(str(part) for part in item["loc"]),
                    "message": item["msg"],
                    "type": item["type"],
                }
                for item in error.errors()
            ]
        }
        return _response(
            request,
            status_code=400,
            code="validation_error",
            message="Request validation failed",
            details=details,
        )

    app.add_exception_handler(VersionConflictError, version_handler)
    app.add_exception_handler(RequestValidationError, validation_handler)
