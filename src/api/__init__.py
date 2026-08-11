"""API package with lazy exports for optional runtime dependencies."""

__all__ = [
    "router",
    "CandidateItemResponse",
    "ReminderSuggestionResponse",
    "SourceTextSpanResponse",
    "CalendarEventCreate",
    "CalendarEventResponse",
    "ParseTextRequest",
    "ParseTextResponse",
    "SyncRequest",
    "SyncResponse",
    "ExportRequest",
    "ExportResponse",
]


def __getattr__(name):
    """Load FastAPI routes and Pydantic schemas only when requested."""
    if name == "router":
        from .routes import router

        return router
    if name in __all__:
        from . import schemas

        return getattr(schemas, name)
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
