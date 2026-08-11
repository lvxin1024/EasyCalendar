"""Calendar client adapters with optional provider dependencies."""

from .base_client import BaseCalendarClient

__all__ = [
    "BaseCalendarClient",
    "GoogleCalendarClient",
    "OutlookCalendarClient",
    "ICalClient",
]


def __getattr__(name):
    """Load optional calendar providers only when requested."""
    if name == "GoogleCalendarClient":
        from .google_calendar import GoogleCalendarClient

        return GoogleCalendarClient
    if name == "OutlookCalendarClient":
        from .outlook_calendar import OutlookCalendarClient

        return OutlookCalendarClient
    if name == "ICalClient":
        from .ical_client import ICalClient

        return ICalClient
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
