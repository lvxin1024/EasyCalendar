"""Pure response builders for health and capability discovery."""

from typing import Any, Dict, Optional

from config.loader import Settings, load_settings
from ..domain import DOMAIN_SCHEMA_VERSION


SERVICE_VERSION = "0.1.0"
SCHEMA_VERSION = DOMAIN_SCHEMA_VERSION


def build_health_payload(settings: Optional[Settings] = None) -> Dict[str, Any]:
    """Return a non-sensitive liveness payload."""
    active_settings = settings or load_settings()
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
    active_settings = settings or load_settings()
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
            "items": True,
            "sync": False,
            "ics_subscriptions": True,
            "assistant": True,
            "local_reminders": True,
            "json_backup": True,
            "ics_transfer": True,
            "widget_snapshot": True,
        },
        "configured": {
            "sync": active_settings.sync.enabled,
            "ics_subscriptions": active_settings.subscriptions.enabled,
            "assistant": active_settings.assistant.enabled,
            "local_reminders": active_settings.notifications.enabled,
            "widget_snapshot": active_settings.widget.enabled,
        },
        "authentication": {
            "required": active_settings.secrets.admin_token is not None,
            "scheme": "bearer",
        },
        "providers": {
            "parser": ["rules.zh_cn"],
            "ai": ai_providers,
            "notification": [active_settings.notifications.adapter],
        },
        "runtime": {
            "mode": active_settings.server.mode,
            "timezone": active_settings.app.timezone,
            "locale": active_settings.app.locale,
        },
    }
