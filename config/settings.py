"""Configuration settings for EasyCalendar."""

import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent

GOOGLE_CALENDAR_CONFIG = {
    "credentials_file": os.getenv("GOOGLE_CREDENTIALS_FILE", "config/google_credentials.json"),
    "token_file": os.getenv("GOOGLE_TOKEN_FILE", "config/google_token.json"),
}

OUTLOOK_CONFIG = {
    "client_id": os.getenv("OUTLOOK_CLIENT_ID", ""),
    "client_secret": os.getenv("OUTLOOK_CLIENT_SECRET", ""),
    "tenant_id": os.getenv("OUTLOOK_TENANT_ID", "common"),
}

ICAL_CONFIG = {
    "output_dir": os.getenv("ICAL_OUTPUT_DIR", "config/calendars"),
}

API_CONFIG = {
    "host": os.getenv("API_HOST", "0.0.0.0"),
    "port": int(os.getenv("API_PORT", "8000")),
    "debug": os.getenv("API_DEBUG", "False").lower() == "true",
}
