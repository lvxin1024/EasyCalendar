"""Validated configuration loading for EasyCalendar."""

from __future__ import annotations

import json
import os
from copy import deepcopy
from pathlib import Path
from typing import Any, Dict, Literal, Mapping, Optional

from dotenv import dotenv_values
from pydantic import BaseModel, ConfigDict, Field, SecretStr, ValidationError, model_validator


BASE_DIR = Path(__file__).resolve().parent.parent
DEFAULT_CONFIG_PATH = BASE_DIR / "config" / "app.yaml"
DEFAULT_SECRETS_PATH = BASE_DIR / "config" / "secrets.env"


class ConfigurationError(ValueError):
    """Raised when runtime configuration is missing or invalid."""


class StrictModel(BaseModel):
    """Base configuration model that catches misspelled keys."""

    model_config = ConfigDict(extra="forbid")


class AppSettings(StrictModel):
    name: str = "EasyCalendar"
    instance_name: str = "my-easycalendar"
    timezone: str = "Asia/Shanghai"
    locale: str = "zh-CN"
    data_dir: str = "./data"
    default_collection_id: str = Field(
        default="collection_local", min_length=1, max_length=200
    )
    default_collection_name: str = Field(
        default="我的日程", min_length=1, max_length=200
    )
    default_collection_color: Optional[str] = Field(
        default="#2563EB", pattern=r"^#[0-9A-Fa-f]{6}$"
    )


class ServerSettings(StrictModel):
    mode: Literal["local", "cloudflare", "docker"] = "local"
    host: str = "0.0.0.0"
    port: int = Field(default=8000, ge=1, le=65535)
    debug: bool = False
    public_url: Optional[str] = "http://localhost:8000"
    cors_allowed_origins: list[str] = Field(
        default_factory=lambda: ["http://localhost:8000"]
    )


class StorageSettings(StrictModel):
    driver: Literal["sqlite", "d1"] = "sqlite"
    sqlite_path: str = "./data/app.sqlite3"
    backup_dir: str = "./data/backups"


class SyncSettings(StrictModel):
    enabled: bool = False
    pull_limit: int = Field(default=200, ge=1, le=1000)
    retry_limit: int = Field(default=8, ge=0, le=100)


class SubscriptionSettings(StrictModel):
    enabled: bool = True
    refresh_cron: str = "0 */6 * * *"
    request_timeout_seconds: int = Field(default=20, ge=1, le=300)


class AssistantSettings(StrictModel):
    enabled: bool = False
    provider: Literal["rules", "openai_compatible", "ollama"] = "rules"
    base_url: Optional[str] = None
    model: Optional[str] = None
    timeout_seconds: int = Field(default=45, ge=1, le=600)
    max_input_chars: int = Field(default=20000, ge=1, le=1000000)


class NotificationSettings(StrictModel):
    enabled: bool = False
    adapter: Literal["memory"] = "memory"
    restore_on_start: bool = True


class IntegrationSettings(StrictModel):
    ical_output_dir: str = "./config/calendars"
    google_credentials_file: str = "./config/google_credentials.json"
    google_token_file: str = "./config/google_token.json"
    outlook_tenant_id: str = "common"


class WidgetSettings(StrictModel):
    enabled: bool = False
    snapshot_path: str = "./data/widget/snapshot.json"


class DeploymentSettings(StrictModel):
    provider: Literal["docker", "cloudflare"] = "docker"
    auto_migrate: bool = True
    auto_backup_before_migrate: bool = True


class SecretSettings(StrictModel):
    admin_token: Optional[SecretStr] = None
    ai_api_key: Optional[SecretStr] = None
    outlook_client_id: Optional[SecretStr] = None
    outlook_client_secret: Optional[SecretStr] = None


class Settings(StrictModel):
    app: AppSettings = Field(default_factory=AppSettings)
    server: ServerSettings = Field(default_factory=ServerSettings)
    storage: StorageSettings = Field(default_factory=StorageSettings)
    sync: SyncSettings = Field(default_factory=SyncSettings)
    subscriptions: SubscriptionSettings = Field(default_factory=SubscriptionSettings)
    assistant: AssistantSettings = Field(default_factory=AssistantSettings)
    notifications: NotificationSettings = Field(default_factory=NotificationSettings)
    integrations: IntegrationSettings = Field(default_factory=IntegrationSettings)
    widget: WidgetSettings = Field(default_factory=WidgetSettings)
    deployment: DeploymentSettings = Field(default_factory=DeploymentSettings)
    secrets: SecretSettings = Field(default_factory=SecretSettings, exclude=True)

    @model_validator(mode="after")
    def validate_enabled_features(self) -> "Settings":
        if self.sync.enabled:
            if self.secrets.admin_token is None:
                raise ValueError("ADMIN_TOKEN is required when sync.enabled is true")
            if not self.server.public_url:
                raise ValueError("server.public_url is required when sync.enabled is true")

        if self.assistant.enabled and self.assistant.provider != "rules":
            if not self.assistant.base_url:
                raise ValueError(
                    "assistant.base_url is required for non-rules providers"
                )
            if not self.assistant.model:
                raise ValueError("assistant.model is required when assistant is enabled")
            if (
                self.assistant.provider == "openai_compatible"
                and self.secrets.ai_api_key is None
            ):
                raise ValueError(
                    "AI_API_KEY is required for the openai_compatible provider"
                )

        if self.server.mode != "local" and "*" in self.server.cors_allowed_origins:
            raise ValueError("server.cors_allowed_origins cannot contain '*' outside local mode")

        return self


LEGACY_ENV_OVERRIDES = {
    "API_HOST": ("server", "host"),
    "API_PORT": ("server", "port"),
    "API_DEBUG": ("server", "debug"),
    "DEFAULT_TIMEZONE": ("app", "timezone"),
    "AI_PROVIDER": ("assistant", "provider"),
    "AI_BASE_URL": ("assistant", "base_url"),
    "AI_MODEL": ("assistant", "model"),
    "ICAL_OUTPUT_DIR": ("integrations", "ical_output_dir"),
    "GOOGLE_CREDENTIALS_FILE": ("integrations", "google_credentials_file"),
    "GOOGLE_TOKEN_FILE": ("integrations", "google_token_file"),
    "OUTLOOK_TENANT_ID": ("integrations", "outlook_tenant_id"),
}


def _deep_merge(base: Dict[str, Any], override: Mapping[str, Any]) -> Dict[str, Any]:
    result = deepcopy(base)
    for key, value in override.items():
        if isinstance(value, Mapping) and isinstance(result.get(key), Mapping):
            result[key] = _deep_merge(dict(result[key]), value)
        else:
            result[key] = deepcopy(value)
    return result


def _read_yaml(path: Path) -> Dict[str, Any]:
    try:
        import yaml
    except ModuleNotFoundError as error:
        raise ConfigurationError(
            "PyYAML is required to read config/app.yaml; install project requirements"
        ) from error

    try:
        content = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as error:
        raise ConfigurationError(f"Cannot read configuration file {path}: {error}") from error

    if content is None:
        return {}
    if not isinstance(content, dict):
        raise ConfigurationError(f"Configuration root must be an object: {path}")
    return content


def _parse_env_value(value: str) -> Any:
    lowered = value.lower()
    if lowered in {"true", "false"}:
        return lowered == "true"
    if lowered in {"null", "none"}:
        return None
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        return value


def _set_nested(target: Dict[str, Any], path: tuple[str, ...], value: Any) -> None:
    current = target
    for part in path[:-1]:
        child = current.setdefault(part, {})
        if not isinstance(child, dict):
            raise ConfigurationError(
                f"Environment override conflicts with non-object key: {'.'.join(path)}"
            )
        current = child
    current[path[-1]] = value


def _resolve_path(
    explicit_path: Optional[Path | str],
    env_name: str,
    default_path: Path,
    environ: Mapping[str, str],
) -> tuple[Path, bool]:
    configured_path = explicit_path or environ.get(env_name)
    return Path(configured_path or default_path), configured_path is not None


def load_settings(
    config_path: Optional[Path | str] = None,
    secrets_path: Optional[Path | str] = None,
    environ: Optional[Mapping[str, str]] = None,
) -> Settings:
    """Load defaults, config files, and environment overrides."""
    process_env = dict(os.environ if environ is None else environ)
    resolved_config, config_was_explicit = _resolve_path(
        config_path, "EASYCALENDAR_CONFIG", DEFAULT_CONFIG_PATH, process_env
    )
    resolved_secrets, secrets_was_explicit = _resolve_path(
        secrets_path, "EASYCALENDAR_SECRETS", DEFAULT_SECRETS_PATH, process_env
    )

    if config_was_explicit and not resolved_config.exists():
        raise ConfigurationError(f"Configuration file does not exist: {resolved_config}")
    if secrets_was_explicit and not resolved_secrets.exists():
        raise ConfigurationError(f"Secrets file does not exist: {resolved_secrets}")

    values: Dict[str, Any] = {}
    if resolved_config.exists():
        values = _read_yaml(resolved_config)

    environment_name = process_env.get("EASYCALENDAR_ENV")
    if environment_name:
        environment_path = (
            BASE_DIR / "config" / "environments" / f"{environment_name}.yaml"
        )
        if not environment_path.exists():
            raise ConfigurationError(
                f"Environment configuration does not exist: {environment_path}"
            )
        values = _deep_merge(values, _read_yaml(environment_path))

    if "secrets" in values:
        raise ConfigurationError(
            "Secrets must be stored in config/secrets.env or process environment variables"
        )

    secret_file_values: Dict[str, str] = {}
    if resolved_secrets.exists():
        secret_file_values = {
            key: value
            for key, value in dotenv_values(resolved_secrets).items()
            if value is not None
        }
    effective_env = {**secret_file_values, **process_env}

    for env_name, path in LEGACY_ENV_OVERRIDES.items():
        if env_name in effective_env:
            _set_nested(values, path, _parse_env_value(effective_env[env_name]))

    prefix = "EASYCALENDAR__"
    for env_name, value in effective_env.items():
        if env_name.startswith(prefix):
            path = tuple(part.lower() for part in env_name[len(prefix) :].split("__"))
            if not all(path):
                raise ConfigurationError(f"Invalid environment override: {env_name}")
            if path[0] == "secrets":
                raise ConfigurationError(
                    "Use ADMIN_TOKEN, AI_API_KEY, or provider-specific secret variables"
                )
            _set_nested(values, path, _parse_env_value(value))

    values = _deep_merge(
        values,
        {
            "secrets": {
                "admin_token": effective_env.get("ADMIN_TOKEN") or None,
                "ai_api_key": effective_env.get("AI_API_KEY") or None,
                "outlook_client_id": effective_env.get("OUTLOOK_CLIENT_ID") or None,
                "outlook_client_secret": effective_env.get("OUTLOOK_CLIENT_SECRET") or None,
            }
        },
    )

    try:
        return Settings.model_validate(values)
    except ValidationError as error:
        messages = []
        for detail in error.errors(include_input=False):
            location = ".".join(str(part) for part in detail["loc"]) or "configuration"
            messages.append(f"{location}: {detail['msg']}")
        raise ConfigurationError("Invalid configuration: " + "; ".join(messages)) from error
