"""Versioned health and capability discovery routes."""

from fastapi import APIRouter

from .system import build_capabilities_payload, build_health_payload


router = APIRouter(prefix="/v1", tags=["system"])


@router.get("/health")
async def health_check():
    """Return service liveness without contacting optional providers."""
    return build_health_payload()


@router.get("/capabilities")
async def capabilities():
    """Return available and configured features without exposing secrets."""
    return build_capabilities_payload()
