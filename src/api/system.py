"""Pure response builders for health and capability discovery."""

from importlib.util import find_spec
from typing import Any, Dict, Optional

from config.loader import Settings
from config.settings import SETTINGS
from ..domain import DOMAIN_SCHEMA_VERSION


SERVICE_VERSION = "0.1.0"
SCHEMA_VERSION = DOMAIN_SCHEMA_VERSION


def _modules_available(*module_names: str) -> bool:
    for module_name in module_names:
        try:
            if find_spec(module_name) is None:
                return False
        except (ImportError, ModuleNotFoundError):
            return False
    return True


def build_health_payload(settings: Optional[Settings] = None) -> Dict[str, Any]:
    """Return a non-sensitive liveness payload."""
    active_settings = settings or SETTINGS
    return {
        "status": "ok",
        "service": "easycalendar",
        "instance": active_settings.app.instance_name,
        "version": SERVICE_VERSION,
        "schema_version": SCHEMA_VERSION,
    }


def build_capabilities_payload(
    settings: Optional[Settings] = None,
) -> Dict[str, Any]:
    """Return implemented and configured capabilities without secrets."""
    active_settings = settings or SETTINGS
    ai_providers = (
        [active_settings.assistant.provider]
        if active_settings.assistant.enabled
        else []
    )

    return {
        "api_version": "v1",
        "service_version": SERVICE_VERSION,
        "schema_version": SCHEMA_VERSION,
        "features": {
            "parser": True,
            "items": False,
            "sync": False,
            "ics_subscriptions": False,
            "assistant": False,
            "widget_snapshot": False,
        },
        "configured": {
            "sync": active_settings.sync.enabled,
            "ics_subscriptions": active_settings.subscriptions.enabled,
            "assistant": active_settings.assistant.enabled,
            "widget_snapshot": active_settings.widget.enabled,
        },
        "providers": {
            "parser": ["rules.zh_cn"],
            "ai": ai_providers,
            "calendar": {
                "ical": _modules_available("vobject"),
                "google": _modules_available(
                    "google.oauth2.credentials",
                    "google_auth_oauthlib.flow",
                    "googleapiclient.discovery",
                    "icalendar",
                ),
                "microsoft": _modules_available("msal", "requests", "icalendar"),
            },
        },
        "runtime": {
            "mode": active_settings.server.mode,
            "timezone": active_settings.app.timezone,
            "locale": active_settings.app.locale,
        },
    }
