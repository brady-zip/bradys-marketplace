#!/usr/bin/env bash
# Doctor never repairs. --offline and --smoke are explicit diagnostic scopes.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$SCRIPT_DIR/preflight.sh" --skill doctor "$@"
