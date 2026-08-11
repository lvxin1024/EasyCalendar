"""Versioned health and capability discovery routes."""

from fastapi import APIRouter, Request

from .system import build_capabilities_payload, build_health_payload


router = APIRouter(prefix="/v1", tags=["system"])


@router.get("/health")
async def health_check(request: Request):
    """Return service liveness without contacting external services."""
    return build_health_payload(request.app.state.settings)


@router.get("/capabilities")
async def capabilities(request: Request):
    """Return available and configured features without exposing secrets."""
    return build_capabilities_payload(request.app.state.settings)
