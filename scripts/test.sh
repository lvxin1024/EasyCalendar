#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON:-python3}"
VENV_DIR="${EASYCALENDAR_TEST_VENV:-${PROJECT_DIR}/.venv-test}"
MODE="${1:-core}"

case "${MODE}" in
    core)
        REQUIREMENTS=("${PROJECT_DIR}/requirements-dev.txt")
        ;;
    providers)
        REQUIREMENTS=(
            "${PROJECT_DIR}/requirements-dev.txt"
            "${PROJECT_DIR}/requirements-providers.txt"
        )
        ;;
    *)
        echo "Usage: $0 [core|providers]" >&2
        exit 2
        ;;
esac

"${PYTHON_BIN}" -c 'import sys; assert sys.version_info >= (3, 11), "EasyCalendar requires Python 3.11 or newer"'

if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
    "${PYTHON_BIN}" -m venv "${VENV_DIR}"
fi

PIP_ARGS=()
for requirement in "${REQUIREMENTS[@]}"; do
    PIP_ARGS+=(-r "${requirement}")
done

"${VENV_DIR}/bin/python" -m pip install --disable-pip-version-check "${PIP_ARGS[@]}"
cd "${PROJECT_DIR}"
if [[ "${MODE}" == "core" ]]; then
    "${VENV_DIR}/bin/python" -m pytest -m "not provider"
else
    "${VENV_DIR}/bin/python" -m pytest
fi
