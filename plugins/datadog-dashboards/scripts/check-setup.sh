#!/usr/bin/env bash
#
# Setup check for the datadog-dashboards plugin.
#
# This is a thin wrapper around preflight.sh, kept because the README and the
# plugin's docs have always pointed people here. The two used to be separate
# implementations of the same checks, which is exactly the arrangement that lets
# them drift: preflight would learn about a new dependency and this file would
# quietly keep reporting a green machine. There is now one implementation.
#
# The difference is only in posture:
#
#   check-setup.sh  -- diagnostic. Checks everything for every skill and does not
#                      modify your machine. This is what a user runs when they
#                      want to know its state, or a maintainer runs before filing
#                      a bug.
#
#                      "Does not modify your machine" is not "free". It makes two
#                      live outbound API calls: one to Datadog /api/v1/validate,
#                      and one real (tiny) Gemini completion. The Gemini call is
#                      BILLABLE. Do not put this in a cron job or a CI loop that
#                      runs per-commit without thinking about that.
#
#   preflight.sh    -- gate. Runs automatically at the top of every skill
#                      invocation, scoped to the skill about to run, and repairs
#                      what it can rather than reporting it.
#
# Pass --repair to let this script fix things too (identical to running
# preflight.sh directly). Any other arguments are forwarded to preflight.sh.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREFLIGHT="$SCRIPT_DIR/preflight.sh"

if [ ! -x "$PREFLIGHT" ]; then
  printf 'check-setup: %s is missing or not executable.\n' "$PREFLIGHT" >&2
  printf 'Reinstall the plugin: claude plugin install datadog-dashboards@bradys-marketplace\n' >&2
  exit 1
fi

# Default to read-only. `--repair` opts back in to preflight's self-healing.
MODE="--no-repair"
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --repair) MODE="" ;;
    *) ARGS+=("$arg") ;;
  esac
done

# --skill all is the right default for a diagnostic: report every dependency any
# skill in the chain needs, rather than only the ones blocking one entry point.
# --smoke makes the live Gemini call, because "llm lists a gemini model" and
# "gemini answers" are different facts and only the second one matters.
exec bash "$PREFLIGHT" --skill all --smoke ${MODE:+$MODE} ${ARGS+"${ARGS[@]}"}
