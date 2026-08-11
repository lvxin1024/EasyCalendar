#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER_DIR="${PROJECT_DIR}/server"

command -v node >/dev/null 2>&1 || { echo "setup: Node.js 22 is required" >&2; exit 1; }
command -v npm >/dev/null 2>&1 || { echo "setup: npm is required" >&2; exit 1; }

NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [[ "${NODE_MAJOR}" != "22" ]]; then
    echo "setup: Node.js 22 is required (found $(node --version))" >&2
    exit 1
fi

ACTION="${1:-setup}"
if [[ "${ACTION}" == "install" ]]; then
    npm --prefix "${SERVER_DIR}" ci
    exit 0
fi

if [[ ! -x "${SERVER_DIR}/node_modules/.bin/wrangler" ]]; then
    echo "setup: Worker dependencies are missing; run ./scripts/setup.sh install" >&2
    exit 1
fi

exec node "${SERVER_DIR}/scripts/setup.mjs" "$@"
