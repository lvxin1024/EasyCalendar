#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT_DIR="${PROJECT_DIR}/client"
EXPECTED_VERSION="$(sed -n 's/.*"flutter"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${CLIENT_DIR}/.fvmrc")"
LOCAL_FLUTTER_BIN="${PROJECT_DIR}/.tools/flutter/bin/flutter.bat"

export FLUTTER_SUPPRESS_ANALYTICS=true

if [[ -n "${FLUTTER_BIN:-}" ]]; then
    :
elif [[ -x "${LOCAL_FLUTTER_BIN}" ]]; then
    FLUTTER_BIN="${LOCAL_FLUTTER_BIN}"
elif command -v flutter >/dev/null 2>&1; then
    FLUTTER_BIN="$(command -v flutter)"
elif [[ -x "${HOME}/flutter/bin/flutter" ]]; then
    FLUTTER_BIN="${HOME}/flutter/bin/flutter"
else
    echo "Flutter ${EXPECTED_VERSION} is required. Install it or set FLUTTER_BIN." >&2
    exit 1
fi

if [[ ! -f "${PROJECT_DIR}/config/client.json" ]]; then
    cp "${PROJECT_DIR}/config/client.example.json" "${PROJECT_DIR}/config/client.json"
fi

ACTUAL_VERSION="$("${FLUTTER_BIN}" --version --machine | sed -n 's/.*"frameworkVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
if [[ "${ACTUAL_VERSION}" != "${EXPECTED_VERSION}" ]]; then
    echo "Expected Flutter ${EXPECTED_VERSION}, found ${ACTUAL_VERSION:-unknown}." >&2
    exit 1
fi

cd "${CLIENT_DIR}"
GENERATED_ROOT="$(mktemp -d)"
trap 'rm -rf "${GENERATED_ROOT}"' EXIT
"${FLUTTER_BIN}" create \
    --project-name easy_calendar \
    --org io.easycalendar \
    --platforms android,macos,windows \
    "${GENERATED_ROOT}/easy_calendar"
for platform in android macos windows; do
    if [[ ! -d "${CLIENT_DIR}/${platform}" ]]; then
        cp -R "${GENERATED_ROOT}/easy_calendar/${platform}" "${CLIENT_DIR}/${platform}"
    fi
done
cp "${GENERATED_ROOT}/easy_calendar/.metadata" "${CLIENT_DIR}/.metadata"
"${FLUTTER_BIN}" pub get
"${FLUTTER_BIN}" analyze
"${FLUTTER_BIN}" test
