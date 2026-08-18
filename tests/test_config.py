"""Tests for validated runtime configuration and capability discovery."""

import json
import sys
from types import SimpleNamespace
from pathlib import Path

import pytest
from pydantic import ValidationError

from config.loader import ConfigurationError, Settings, load_settings
from src.api.system import build_capabilities_payload, build_health_payload


PROJECT_ROOT = Path(__file__).resolve().parent.parent


def test_default_settings_are_local_and_safe():
    settings = load_settings(environ={})

    assert settings.app.name == "EasyCalendar"
    assert settings.server.mode == "local"
    assert settings.server.cors_allowed_origins == ["http://localhost:8000"]
    assert settings.sync.enabled is False
    assert settings.assistant.enabled is False
    assert settings.assistant.max_input_chars == 20000
    assert settings.notifications.enabled is False
    assert settings.notifications.adapter == "memory"
    assert settings.transfer.max_import_bytes == 10485760


def test_nested_environment_overrides_are_supported():
    settings = load_settings(
        environ={
            "EASYCALENDAR__SERVER__PORT": "8200",
            "EASYCALENDAR__APP__TIMEZONE": "UTC",
            "EASYCALENDAR__SERVER__CORS_ALLOWED_ORIGINS": '["https://app.example.com"]',
        }
    )

    assert settings.server.port == 8200
    assert settings.app.timezone == "UTC"
    assert settings.server.cors_allowed_origins == ["https://app.example.com"]


def test_removed_legacy_environment_alias_is_ignored():
    settings = load_settings(environ={"API_PORT": "8100"})

    assert settings.server.port == 8000


def test_secrets_file_is_loaded_but_never_exposed(tmp_path):
    secrets_path = tmp_path / "secrets.env"
    secrets_path.write_text("ADMIN_TOKEN=private-token\n", encoding="utf-8")

    settings = load_settings(
        secrets_path=secrets_path,
        environ={
            "EASYCALENDAR__SYNC__ENABLED": "true",
            "EASYCALENDAR__SERVER__PUBLIC_URL": "https://calendar.example.com",
        },
    )
    payload = build_capabilities_payload(settings)

    assert settings.secrets.admin_token.get_secret_value() == "private-token"
    assert "private-token" not in json.dumps(payload)
    assert payload["configured"]["sync"] is True


def test_sync_requires_admin_token():
    with pytest.raises(ConfigurationError, match="ADMIN_TOKEN"):
        load_settings(
            environ={
                "EASYCALENDAR__SYNC__ENABLED": "true",
                "EASYCALENDAR__SERVER__PUBLIC_URL": "https://calendar.example.com",
            }
        )


def test_unknown_config_keys_are_rejected():
    with pytest.raises(ValidationError, match="extra_forbidden"):
        Settings.model_validate({"app": {"timezome": "UTC"}})


def test_secrets_cannot_be_stored_in_app_config(monkeypatch, tmp_path):
    fake_yaml = SimpleNamespace(
        safe_load=json.loads,
        YAMLError=ValueError,
    )
    monkeypatch.setitem(sys.modules, "yaml", fake_yaml)

    config_path = tmp_path / "app.yaml"
    config_path.write_text(
        json.dumps({"secrets": {"admin_token": "must-not-leak"}}),
        encoding="utf-8",
    )

    with pytest.raises(ConfigurationError, match="config/secrets.env") as error:
        load_settings(config_path=config_path, environ={})

    assert "must-not-leak" not in str(error.value)


def test_explicit_missing_config_is_rejected(tmp_path):
    with pytest.raises(ConfigurationError, match="does not exist"):
        load_settings(config_path=tmp_path / "missing.yaml", environ={})


def test_yaml_config_is_merged_with_environment(monkeypatch, tmp_path):
    fake_yaml = SimpleNamespace(
        safe_load=json.loads,
        YAMLError=ValueError,
    )
    monkeypatch.setitem(sys.modules, "yaml", fake_yaml)

    config_path = tmp_path / "app.yaml"
    config_path.write_text(
        json.dumps({"app": {"timezone": "Europe/London"}, "server": {"port": 9000}}),
        encoding="utf-8",
    )

    settings = load_settings(
        config_path=config_path,
        environ={"EASYCALENDAR__SERVER__PORT": "9001"},
    )

    assert settings.app.timezone == "Europe/London"
    assert settings.server.port == 9001


def test_example_yaml_matches_the_runtime_schema():
    settings = load_settings(
        config_path=PROJECT_ROOT / "config" / "app.example.yaml",
        environ={},
    )

    assert settings.app.name == "EasyCalendar"
    assert settings.transfer.max_import_bytes == 10485760


def test_health_and_capabilities_are_truthful():
    settings = Settings()

    health = build_health_payload(settings)
    capabilities = build_capabilities_payload(settings)

    assert health["service"] == "easycalendar"
    assert health["instance"] == "my-easycalendar"
    assert capabilities["features"]["parser"] is True
    assert capabilities["features"]["items"] is True
    assert capabilities["features"]["assistant"] is True
    assert capabilities["features"]["local_reminders"] is True
    assert capabilities["features"]["json_backup"] is True
    assert capabilities["features"]["ics_transfer"] is True
    assert capabilities["configured"]["local_reminders"] is False
    assert capabilities["providers"]["notification"] == ["memory"]
    assert capabilities["providers"]["parser"] == ["rules.zh_cn"]


def test_versioned_system_endpoints_start_with_core_dependencies():
    from fastapi.testclient import TestClient

    from src.main import create_app

    client = TestClient(create_app())

    health_response = client.get("/v1/health")
    capabilities_response = client.get("/v1/capabilities")

    assert client.app.version == health_response.json()["version"]
    assert health_response.status_code == 200
    assert health_response.json()["service"] == "easycalendar"
    assert capabilities_response.status_code == 200
    assert capabilities_response.json()["features"]["parser"] is True
    assert "calendar" not in capabilities_response.json()["providers"]
    assert client.get("/v1/auth-check").json() == {"status": "ok"}
    assert client.get("/api/v1/health").status_code == 404


def test_configured_admin_token_protects_core_business_routes(tmp_path):
    from fastapi.testclient import TestClient

    from src.main import create_app
    from src.storage import SQLiteRepository

    settings = Settings(secrets={"admin_token": "core-private-token"})
    repository = SQLiteRepository(tmp_path / "authenticated-core.sqlite3")
    with TestClient(create_app(settings, repository=repository)) as client:
        assert client.get("/v1/health").status_code == 200
        capabilities = client.get("/v1/capabilities")
        assert capabilities.status_code == 200
        assert capabilities.json()["authentication"]["required"] is True

        rejected = client.get("/v1/items")
        assert rejected.status_code == 401
        assert rejected.json()["error"]["code"] == "authentication_required"

        auth_check = client.get(
            "/v1/auth-check",
            headers={"Authorization": "Bearer core-private-token"},
        )
        assert auth_check.status_code == 200
        assert auth_check.json() == {"status": "ok"}

        accepted = client.get(
            "/v1/items",
            headers={"Authorization": "Bearer core-private-token"},
        )
        assert accepted.status_code == 200
