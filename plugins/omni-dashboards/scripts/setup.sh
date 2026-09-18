#!/usr/bin/env bash
# Credential input is exclusively delegated to the official CLI on a user TTY.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1
exec python3 "$SCRIPT_DIR/setup.py" "$@"
