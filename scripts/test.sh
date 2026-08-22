#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="${EASYCALENDAR_TEST_VENV:-${PROJECT_DIR}/.venv-test}"
WINDOWS=0

case "$(uname -s 2>/dev/null || echo "")" in
    MINGW*|MSYS*|CYGWIN*|Windows_NT)
        WINDOWS=1
        ;;
esac

if [[ -n "${PYTHON:-}" ]]; then
    read -r -a PYTHON_CMD <<< "${PYTHON}"
elif command -v py >/dev/null 2>&1; then
    PYTHON_CMD=(py -3)
elif command -v python3 >/dev/null 2>&1; then
    PYTHON_CMD=(python3)
elif command -v python >/dev/null 2>&1; then
    PYTHON_CMD=(python)
else
    echo "EasyCalendar requires Python 3.11 or newer" >&2
    exit 1
fi

if [[ "${WINDOWS}" -eq 1 ]]; then
    VENV_PYTHON="${VENV_DIR}/Scripts/python.exe"
else
    VENV_PYTHON="${VENV_DIR}/bin/python"
fi

"${PYTHON_CMD[@]}" -c 'import sys; assert sys.version_info >= (3, 11), "EasyCalendar requires Python 3.11 or newer"'

if [[ ! -x "${VENV_PYTHON}" ]]; then
    "${PYTHON_CMD[@]}" -m venv "${VENV_DIR}"
fi

"${VENV_PYTHON}" -m pip install --disable-pip-version-check -r "${PROJECT_DIR}/requirements-dev.txt"
cd "${PROJECT_DIR}"
"${VENV_PYTHON}" -m pytest
