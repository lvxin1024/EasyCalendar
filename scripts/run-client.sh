#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${EASYCALENDAR_CLIENT_CONFIG:-${PROJECT_DIR}/config/client.json}"
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
    echo "Flutter is required. Install it or set FLUTTER_BIN." >&2
    exit 1
fi

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "Missing client config: ${CONFIG_FILE}" >&2
    echo "Create it from config/client.example.json." >&2
    exit 1
fi

DEVICE_ARGS=()
if [[ -n "${EASYCALENDAR_CLIENT_DEVICE:-}" ]]; then
    case "${EASYCALENDAR_CLIENT_DEVICE}" in
        chrome|web-server)
            echo "Web is not a supported EasyCalendar client target." >&2
            exit 2
            ;;
    esac
    DEVICE_ARGS=(-d "${EASYCALENDAR_CLIENT_DEVICE}")
elif [[ "$(uname -s)" == "Darwin" ]]; then
    DEVICE_ARGS=(-d macos)
elif [[ "$(uname -s)" =~ ^(MINGW|MSYS|CYGWIN) ]]; then
    DEVICE_ARGS=(-d windows)
else
    echo "Set EASYCALENDAR_CLIENT_DEVICE to an Android device ID." >&2
    exit 2
fi

cd "${PROJECT_DIR}/client"
"${FLUTTER_BIN}" run "${DEVICE_ARGS[@]}" --dart-define-from-file="${CONFIG_FILE}"
