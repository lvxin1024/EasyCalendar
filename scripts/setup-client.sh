#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT_DIR="${PROJECT_DIR}/client"
EXPECTED_VERSION="3.35.7"

if [[ ! -f "${PROJECT_DIR}/config/client.json" ]]; then
    cp "${PROJECT_DIR}/config/client.example.json" "${PROJECT_DIR}/config/client.json"
fi

if ! command -v flutter >/dev/null 2>&1; then
    echo "Flutter ${EXPECTED_VERSION} is required. Install it or run: fvm install ${EXPECTED_VERSION}" >&2
    exit 1
fi

ACTUAL_VERSION="$(flutter --version --machine | sed -n 's/.*"frameworkVersion":"\([^"]*\)".*/\1/p')"
if [[ "${ACTUAL_VERSION}" != "${EXPECTED_VERSION}" ]]; then
    echo "Expected Flutter ${EXPECTED_VERSION}, found ${ACTUAL_VERSION:-unknown}." >&2
    exit 1
fi

cd "${CLIENT_DIR}"
GENERATED_ROOT="$(mktemp -d)"
trap 'rm -rf "${GENERATED_ROOT}"' EXIT
flutter create \
    --project-name easy_calendar \
    --org io.easycalendar \
    --platforms android,macos,windows \
    "${GENERATED_ROOT}/easy_calendar"
for platform in android macos windows; do
    if [[ ! -d "${CLIENT_DIR}/${platform}" ]]; then
        cp -R "${GENERATED_ROOT}/easy_calendar/${platform}" "${CLIENT_DIR}/${platform}"
    fi
done
if [[ ! -f "${CLIENT_DIR}/.metadata" ]]; then
    cp "${GENERATED_ROOT}/easy_calendar/.metadata" "${CLIENT_DIR}/.metadata"
fi
flutter pub get
flutter analyze
flutter test
