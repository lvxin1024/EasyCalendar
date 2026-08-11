"""Runtime configuration and legacy compatibility dictionaries."""

from .loader import Settings, load_settings


SETTINGS: Settings = load_settings()

APP_CONFIG = SETTINGS.app.model_dump()
SERVER_CONFIG = SETTINGS.server.model_dump()
API_CONFIG = {
    "host": SETTINGS.server.host,
    "port": SETTINGS.server.port,
    "debug": SETTINGS.server.debug,
}

GOOGLE_CALENDAR_CONFIG = {
    "credentials_file": SETTINGS.integrations.google_credentials_file,
    "token_file": SETTINGS.integrations.google_token_file,
}

OUTLOOK_CONFIG = {
    "client_id": (
        SETTINGS.secrets.outlook_client_id.get_secret_value()
        if SETTINGS.secrets.outlook_client_id
        else ""
    ),
    "client_secret": (
        SETTINGS.secrets.outlook_client_secret.get_secret_value()
        if SETTINGS.secrets.outlook_client_secret
        else ""
    ),
    "tenant_id": SETTINGS.integrations.outlook_tenant_id,
}

ICAL_CONFIG = {
    "output_dir": SETTINGS.integrations.ical_output_dir,
}
