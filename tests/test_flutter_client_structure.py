"""Static contracts for the generated Flutter client project."""

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
    assert config["EASYCALENDAR_DEVICE_ID"] == ""
    assert config["EASYCALENDAR_SYNC_ENABLED"] == "false"


def test_flutter_project_declares_pinned_sdk_and_offline_dependencies():
    fvm = json.loads((CLIENT / ".fvmrc").read_text(encoding="utf-8"))
    pubspec = yaml.safe_load((CLIENT / "pubspec.yaml").read_text(encoding="utf-8"))

    assert fvm["flutter"] == "3.44.9"
    assert pubspec["dependencies"]["sqflite"] == "2.4.3"
    assert pubspec["dependencies"]["sqflite_common_ffi"] == "2.4.2"
    assert pubspec["dependencies"]["path_provider"] == "2.1.6"
    assert pubspec["dependencies"]["timezone"] == "0.10.1"
    assert pubspec["dependencies"]["uuid"] == "4.6.0"
    assert pubspec["dependencies"]["http"] == "1.6.0"
    assert pubspec["dependencies"]["connectivity_plus"] == "7.3.1"
    assert pubspec["dependencies"]["flutter_secure_storage"] == "^10.3.1"


def test_t16_views_repository_and_platform_bootstrap_are_present():
    required = [
        "lib/main.dart",
        "lib/app.dart",
        "lib/data/item_repository.dart",
        "lib/data/local_item_repository.dart",
        "lib/sync/http_sync_transport.dart",
        "lib/sync/sync_coordinator.dart",
        "lib/sync/sync_models.dart",
        "lib/sync/sync_repository.dart",
        "lib/sync/token_store.dart",
        "lib/sync/connectivity_monitor.dart",
        "lib/features/today/today_page.dart",
        "lib/features/items/items_page.dart",
        "lib/features/due/due_page.dart",
        "lib/features/editor/item_editor_page.dart",
        "lib/features/settings/settings_page.dart",
        "test/item_controller_test.dart",
        "test/http_sync_transport_test.dart",
        "test/local_sync_repository_test.dart",
        "test/sync_coordinator_test.dart",
        ".metadata",
        "pubspec.lock",
        "android/app/build.gradle.kts",
        "macos/Runner/Configs/AppInfo.xcconfig",
        "windows/runner/main.cpp",
    ]

    assert all((CLIENT / relative).is_file() for relative in required)
    setup = (ROOT / "scripts" / "setup-client.sh").read_text(encoding="utf-8")
    assert "--platforms android,ios,macos,windows" in setup
    assert '"${FLUTTER_BIN}" analyze' in setup
    assert '"${FLUTTER_BIN}" test' in setup
    run = (ROOT / "scripts" / "run-client.sh").read_text(encoding="utf-8")
    assert "Web is not a supported EasyCalendar client target" in run
    assert os.access(ROOT / "scripts" / "setup-client.sh", os.X_OK)
    assert os.access(ROOT / "scripts" / "run-client.sh", os.X_OK)


def test_runtime_data_ignore_does_not_hide_flutter_repository_sources():
    patterns = (ROOT / ".gitignore").read_text(encoding="utf-8").splitlines()

    assert "/data/" in patterns
    assert "data/" not in patterns
    assert (CLIENT / "lib" / "data" / "local_item_repository.dart").is_file()


def test_local_mutations_are_versioned_soft_deleted_and_write_outbox():
    source = (CLIENT / "lib" / "data" / "local_item_repository.dart").read_text(
        encoding="utf-8"
    )

    assert "current.version + 1" in source
    assert "deleted_at" in source
    assert "_writeOutbox(transaction, item, 'create')" in source
    assert "_writeOutbox(transaction, updated, 'update')" in source
    assert "_writeOutbox(transaction, deleted, 'delete')" in source


def test_t23_sync_state_and_credentials_have_explicit_storage_boundaries():
    schema = (CLIENT / "lib" / "data" / "local_database_schema.dart").read_text(
        encoding="utf-8"
    )
    repository = (CLIENT / "lib" / "data" / "local_item_repository.dart").read_text(
        encoding="utf-8"
    )
    token_store = (CLIENT / "lib" / "sync" / "token_store.dart").read_text(
        encoding="utf-8"
    )

    assert "CREATE TABLE sync_state" in schema
    assert "next_attempt_at" in schema
    assert "permanent_failure" in schema
    assert "applyRemoteBatch" in repository
    assert "FlutterSecureStorage" in token_store
    assert "easycalendar_feature_api_token" in token_store
    assert "easycalendar_admin_token" not in repository


def test_t24_conflict_heads_and_recovery_history_are_persisted():
    schema = (CLIENT / "lib" / "data" / "local_database_schema.dart").read_text(
        encoding="utf-8"
    )
    repository = (CLIENT / "lib" / "data" / "local_item_repository.dart").read_text(
        encoding="utf-8"
    )
    models = (CLIENT / "lib" / "sync" / "sync_models.dart").read_text(
        encoding="utf-8"
    )

    assert "static const version = 7;" in schema
    assert "static const schemaVersion = LocalDatabaseSchema.version;" in repository
    assert "version: schemaVersion" in repository
    assert "CREATE TABLE sync_entity_heads" in schema
    assert "CREATE TABLE sync_conflicts" in schema
    assert "listSyncConflicts" in repository
    assert "compareSyncChanges" in models


def test_android_release_build_never_falls_back_to_debug_signing():
    build_gradle = (CLIENT / "android" / "app" / "build.gradle.kts").read_text(
        encoding="utf-8"
    )
    key_template = CLIENT / "android" / "key.properties.example"

    assert 'signingConfigs.getByName("debug")' not in build_gradle
    assert 'signingConfigs.getByName("release")' in build_gradle
    assert "releaseBuildRequested" in build_gradle
    assert "Release signing is not configured" in build_gradle
    assert key_template.is_file()


def test_ci_runs_flutter_analysis_and_tests_with_the_pinned_sdk():
    workflow = (ROOT / ".github" / "workflows" / "tests.yml").read_text(
        encoding="utf-8"
    )

    assert 'flutter-version: "3.44.9"' in workflow
    assert "flutter analyze" in workflow
    assert "flutter test" in workflow
    assert "android-release:" in workflow
    assert "flutter build apk --release --no-pub" in workflow
    assert "macos-release:" in workflow
    assert "-configuration Release" in workflow
    assert "CODE_SIGNING_ALLOWED=NO" in workflow
    assert "windows-release:" in workflow
    assert "flutter build windows --release --no-pub" in workflow
    assert "quality-gate:" in workflow
    assert "needs.android-release.result" in workflow
    assert "actions/upload-artifact" not in workflow


def test_tag_release_builds_only_signed_installers():
    workflow = (ROOT / ".github" / "workflows" / "release.yml").read_text(
        encoding="utf-8"
    )
    installer = (CLIENT / "windows" / "installer.iss").read_text(
        encoding="utf-8"
    )

    assert 'tags:' in workflow
    assert "ANDROID_KEYSTORE_BASE64" in workflow
    assert "WINDOWS_CERTIFICATE_PFX_BASE64" in workflow
    assert "MACOS_CERTIFICATE_P12_BASE64" in workflow
    assert "notarytool submit" in workflow
    assert "release-assets/*.apk" in workflow
    assert "release-assets/*.exe" in workflow
    assert "release-assets/*.dmg" in workflow
    assert "ios:" in workflow
    assert "flutter build ios --release --no-codesign" in workflow
    assert "release-assets/*.ipa" in workflow
    assert "flutter build appbundle" not in workflow
    assert "portable.zip" not in workflow
    assert "symbols.zip" not in workflow
    assert "symbols.tar.gz" not in workflow
    assert "SHA256SUMS.txt" not in workflow
    assert "softprops/action-gh-release@v2" in workflow
    assert "PrivilegesRequired=lowest" in installer
    assert "UninstallDisplayIcon" in installer


def test_unsigned_macos_release_does_not_enable_library_validation():
    workflow = (ROOT / ".github" / "workflows" / "release.yml").read_text(
        encoding="utf-8"
    )
    signed_block, unsigned_and_later = workflow.split(
        "- name: Ad-hoc sign and package unsigned DMG", maxsplit=1
    )
    unsigned_block = unsigned_and_later.split(
        "- uses: actions/upload-artifact@v4", maxsplit=1
    )[0]

    assert "--options runtime" in signed_block
    assert "--options runtime" not in unsigned_block
    assert 'codesign --force --sign - "$binary"' in unsigned_block
    assert 'codesign --force --sign - \\' in unsigned_block
    assert '--entitlements "$entitlements" "$app"' in unsigned_block
    assert "Delete :com.apple.security.application-groups" in unsigned_block
    assert "Delete :keychain-access-groups" in unsigned_block
    assert unsigned_block.count("rm -rf client/build/release/dmg") == 2
    assert (
        "--dart-define=EASYCALENDAR_USE_DATA_PROTECTION_KEYCHAIN="
        "${{ steps.signing.outputs.enabled }}"
    ) in workflow
