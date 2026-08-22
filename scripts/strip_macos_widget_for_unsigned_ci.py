"""Remove the macOS Widget target from unsigned CI builds.

Unsigned macOS CI builds only validate the main application binary. The Widget
target requires App Group entitlements and should be built only in signed
release jobs.
"""

from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
PROJECT_FILE = ROOT / "client" / "macos" / "Runner.xcodeproj" / "project.pbxproj"


def strip_widget_dependency(project_text: str) -> str:
    replacements = {
        "\t\t\t\tECA100000000000000000017 /* Embed Widget */,\n": "",
        "\t\t\t\tECA100000000000000000016 /* PBXTargetDependency */,\n": "",
    }
    updated = project_text
    for old, new in replacements.items():
        updated = updated.replace(old, new)
    return updated


def main() -> None:
    project_text = PROJECT_FILE.read_text(encoding="utf-8")
    PROJECT_FILE.write_text(strip_widget_dependency(project_text), encoding="utf-8")


if __name__ == "__main__":
    main()
