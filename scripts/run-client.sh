#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${EASYCALENDAR_CLIENT_CONFIG:-${PROJECT_DIR}/config/client.json}"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "Missing client config: ${CONFIG_FILE}" >&2
    echo "Create it from config/client.example.json." >&2
    exit 1
fi

DEVICE_ARGS=()
if [[ -n "${EASYCALENDAR_CLIENT_DEVICE:-}" ]]; then
    DEVICE_ARGS=(-d "${EASYCALENDAR_CLIENT_DEVICE}")
fi

cd "${PROJECT_DIR}/client"
flutter run "${DEVICE_ARGS[@]}" --dart-define-from-file="${CONFIG_FILE}"
