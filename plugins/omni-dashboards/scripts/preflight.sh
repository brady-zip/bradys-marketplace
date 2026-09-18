#!/usr/bin/env bash
# One diagnostic implementation; no installs or credential writes on this path.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if ! command -v python3 >/dev/null 2>&1; then
  echo 'FAILED: python3 is required; install Python 3 using your platform installer.'
  echo 'PREFLIGHT_STATUS: BLOCKED'
  exit 1
fi
export PYTHONDONTWRITEBYTECODE=1
exec python3 "$SCRIPT_DIR/preflight.py" "$@"
