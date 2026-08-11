"""Static contracts for the Flutter client when no SDK is installed in CI."""

import json
import os
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parent.parent
CLIENT = ROOT / "client"


def test_client_config_matches_all_dart_environment_keys():
    config = json.loads(
        (ROOT / "config" / "client.example.json").read_text(encoding="utf-8")
    )
    source = (CLIENT / "lib" / "config" / "app_config.dart").read_text(
        encoding="utf-8"
    )
    referenced = {
        part.split("'", 1)[0]
        for part in source.split("EASYCALENDAR_")[1:]
    }
    expected = {key.removeprefix("EASYCALENDAR_") for key in config}

    assert referenced == expected
    assert config["EASYCALENDAR_APP_NAME"] == "EasyCalendar"
    assert config["EASYCALENDAR_SYNC_ENABLED"] == "false"


def test_flutter_project_declares_pinned_sdk_and_offline_dependencies():
    fvm = json.loads((CLIENT / ".fvmrc").read_text(encoding="utf-8"))
    pubspec = yaml.safe_load((CLIENT / "pubspec.yaml").read_text(encoding="utf-8"))

    assert fvm["flutter"] == "3.35.7"
    assert pubspec["dependencies"]["sqflite"] == "2.4.2"
    assert pubspec["dependencies"]["sqflite_common_ffi"] == "2.3.6"
    assert pubspec["dependencies"]["path_provider"] == "2.1.5"
    assert pubspec["dependencies"]["timezone"] == "0.10.1"
    assert pubspec["dependencies"]["uuid"] == "4.5.1"


def test_t16_views_repository_and_platform_bootstrap_are_present():
    required = [
        "lib/main.dart",
        "lib/app.dart",
        "lib/data/item_repository.dart",
        "lib/data/local_item_repository.dart",
        "lib/features/today/today_page.dart",
        "lib/features/items/items_page.dart",
        "lib/features/due/due_page.dart",
        "lib/features/editor/item_editor_page.dart",
        "lib/features/settings/settings_page.dart",
        "test/item_controller_test.dart",
    ]

    assert all((CLIENT / relative).is_file() for relative in required)
    setup = (ROOT / "scripts" / "setup-client.sh").read_text(encoding="utf-8")
    assert "--platforms android,macos,windows" in setup
    assert "flutter analyze" in setup
    assert "flutter test" in setup
    assert os.access(ROOT / "scripts" / "setup-client.sh", os.X_OK)
    assert os.access(ROOT / "scripts" / "run-client.sh", os.X_OK)


def test_local_mutations_are_versioned_soft_deleted_and_write_outbox():
    source = (CLIENT / "lib" / "data" / "local_item_repository.dart").read_text(
        encoding="utf-8"
    )

    assert "current.version + 1" in source
    assert "deleted_at" in source
    assert "_writeOutbox(transaction, item, 'create')" in source
    assert "_writeOutbox(transaction, updated, 'update')" in source
    assert "_writeOutbox(transaction, deleted, 'delete')" in source
