"""Static checks for platform release build hardening."""

from pathlib import Path

from scripts.strip_macos_widget_for_unsigned_ci import strip_widget_dependency


ROOT = Path(__file__).resolve().parent.parent
CLIENT = ROOT / "client"


def test_windows_release_suppresses_third_party_coroutine_header_deprecation():
    cmake = (CLIENT / "windows" / "CMakeLists.txt").read_text(encoding="utf-8")

    assert (
        "add_compile_definitions("
        "_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)"
    ) in cmake


def test_windows_release_copies_native_bridge_from_flutter_build_output():
    cmake = (CLIENT / "windows" / "runner" / "CMakeLists.txt").read_text(
        encoding="utf-8"
    )

    assert '"${CMAKE_SOURCE_DIR}/../build/native/windows/easycalendar_p2p.dll"' in cmake
    assert "native/easycalendar_p2p/target/release" not in cmake


def test_platform_artifact_checks_are_shell_parseable_and_diagnostic():
    workflow = (ROOT / ".github" / "workflows" / "tests.yml").read_text(
        encoding="utf-8"
    )
    release_workflow = (ROOT / ".github" / "workflows" / "release.yml").read_text(
        encoding="utf-8"
    )

    assert '$application = "client\\build\\windows\\x64\\runner\\Release\\EasyCalendar.exe"' in workflow
    assert '$library = "client\\build\\windows\\x64\\runner\\Release\\easycalendar_p2p.dll"' in workflow
    assert 'echo "Missing APK native library: $entry" >&2' in workflow
    assert 'echo "Missing APK native library: $entry" >&2' in release_workflow


def test_macos_builds_use_xcode_26_compatible_runners():
    workflow = (ROOT / ".github" / "workflows" / "tests.yml").read_text(
        encoding="utf-8"
    )
    release_workflow = (ROOT / ".github" / "workflows" / "release.yml").read_text(
        encoding="utf-8"
    )

    assert "runs-on: macos-26" in workflow
    assert "runs-on: macos-26" in release_workflow


def test_unsigned_macos_ci_builds_do_not_embed_the_widget_target():
    workflow = (ROOT / ".github" / "workflows" / "tests.yml").read_text(
        encoding="utf-8"
    )
    release_workflow = (ROOT / ".github" / "workflows" / "release.yml").read_text(
        encoding="utf-8"
    )
    project = (
        CLIENT / "macos" / "Runner.xcodeproj" / "project.pbxproj"
    ).read_text(encoding="utf-8")

    stripped = strip_widget_dependency(project)

    assert "python3 ../scripts/strip_macos_widget_for_unsigned_ci.py" in workflow
    assert "python3 ../scripts/strip_macos_widget_for_unsigned_ci.py" in release_workflow
    assert "ECA100000000000000000017 /* Embed Widget */," in project
    assert "ECA100000000000000000016 /* PBXTargetDependency */," in project
    assert "ECA100000000000000000017 /* Embed Widget */," not in stripped
    assert "ECA100000000000000000016 /* PBXTargetDependency */," not in stripped
