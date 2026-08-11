#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON:-python3}"
VENV_DIR="${EASYCALENDAR_TEST_VENV:-${PROJECT_DIR}/.venv-test}"

"${PYTHON_BIN}" -c 'import sys; assert sys.version_info >= (3, 11), "EasyCalendar requires Python 3.11 or newer"'

if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
    "${PYTHON_BIN}" -m venv "${VENV_DIR}"
fi

"${VENV_DIR}/bin/python" -m pip install --disable-pip-version-check -r "${PROJECT_DIR}/requirements-dev.txt"
cd "${PROJECT_DIR}"
"${VENV_DIR}/bin/python" -m pytest
