#!/usr/bin/env bash
#
# Show how a directory resolves to mem0 scopes, and WHICH layer decided each.
# Run via /mem0-brady:scopes [path].
#
# Scope resolution has four layers (env > repo file > machine rules > default),
# which is one more than anyone can hold in their head while debugging why a
# memory landed somewhere unexpected. This prints the answer and the reason
# together, so a surprising partition is traceable to the line that caused it
# instead of being guessed at.
#
# It also inventories the store, because the expensive mistake with partitions
# is not choosing a bad name — it is choosing a name ONE CHARACTER off an
# existing one. Nothing errors; the write simply starts a fresh partition and
# every memory in the old one becomes invisible to recall. So each app_id this
# machine can resolve to is shown with how many memories it already holds, and
# empty ones are called out as new.
#
# Read-only: resolves config, counts memories, writes nothing.
set -u

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

TARGET="${1:-$PWD}"
case "$TARGET" in
  -h|--help) printf 'usage: %s [path]\n\nShows the mem0 scopes a directory resolves to, and why.\n' "${0##*/}"; exit 0 ;;
esac
[ -d "$TARGET" ] || { printf "${RED}not a directory: %s${NC}\n" "$TARGET" >&2; exit 1; }
TARGET="$(cd "$TARGET" 2>/dev/null && pwd)" || TARGET="${1:-$PWD}"

CONFIG_DIR="${MEM0_BRADY_CONFIG_DIR:-${HOME}/.config/mem0-brady}"
ENV_FILE="${MEM0_BRADY_ENV:-${CONFIG_DIR}/.env}"
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" 2>/dev/null && pwd)/lib-scope.sh"

[ -f "$LIB" ] || { printf "${RED}missing resolver: %s${NC}\n" "$LIB" >&2; exit 1; }

header() { printf "\n${BOLD}${BLUE}%s${NC}\n" "$1"; }
row()    { printf "  %-10s ${BOLD}%-24s${NC} ${DIM}← %s${NC}\n" "$1" "$2" "$3"; }

# Resolve in a subshell so this script's own environment can't leak into the
# answer — the point is to show what a HOOK would resolve, not what happens to
# be exported here.
eval "$(
  # shellcheck disable=SC1090
  . "$LIB"
  mem0_scope_init "$TARGET"
  for v in MEM0_APP_ID MEM0_RECALL_APP_IDS MEM0_AGENT_ID MEM0_USER_ID \
           MEM0_SCOPE_USER_ID_KNOWN MEM0_SCOPE_REPO_FILE \
           MEM0_SCOPE_WHY_APP_ID MEM0_SCOPE_WHY_RECALL_APP_IDS \
           MEM0_SCOPE_WHY_AGENT_ID MEM0_SCOPE_WHY_USER_ID; do
    printf '%s=%q\n' "$v" "${!v:-}"
  done
)"

printf "${BOLD}mem0-brady scopes${NC}  ${DIM}%s${NC}\n" "$TARGET"

header "Config in play"
if [ -f "$ENV_FILE" ]; then
  printf "  ${GREEN}machine${NC}  %s\n" "$ENV_FILE"
else
  printf "  ${YELLOW}machine${NC}  %s ${DIM}(missing — run /mem0-brady:setup)${NC}\n" "$ENV_FILE"
fi
if [ -n "${MEM0_SCOPE_REPO_FILE:-}" ]; then
  printf "  ${GREEN}repo${NC}     %s\n" "$MEM0_SCOPE_REPO_FILE"
else
  printf "  ${DIM}repo     none — no .mem0-brady.json at or above this directory${NC}\n"
fi

header "Resolved"
row "app_id" "$MEM0_APP_ID" "$MEM0_SCOPE_WHY_APP_ID"
row "recall" "$MEM0_RECALL_APP_IDS" "$MEM0_SCOPE_WHY_RECALL_APP_IDS"
row "agent_id" "$MEM0_AGENT_ID" "$MEM0_SCOPE_WHY_AGENT_ID"
if [ "${MEM0_SCOPE_USER_ID_KNOWN:-0}" = "1" ]; then
  row "user_id" "$MEM0_USER_ID" "$MEM0_SCOPE_WHY_USER_ID"
else
  row "user_id" "(server owns it)" "$MEM0_SCOPE_WHY_USER_ID"
fi
row "run_id" "(per session)" "set by /mem0-brady:workstream, not by config"

# --- Store inventory ---------------------------------------------------------
# Everything below is best-effort: a dead or unreachable server costs the
# inventory, never the resolution above.
MCP_URL="${MEM0_BRADY_MCP_URL:-}"
if [ -z "$MCP_URL" ] && [ -f "$ENV_FILE" ]; then
  MCP_URL="$(grep -E '^MEM0_BRADY_MCP_URL=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
fi

# shellcheck source=lib-mcp.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-mcp.sh"

header "In the store"
if ! mcp_init "$MCP_URL"; then
  printf "  ${YELLOW}skipped${NC} — MCP server not reachable at %s\n" "${MCP_URL:-<unset>}"
  printf "  ${DIM}Resolution above is unaffected; only the inventory needs the server.${NC}\n"
  exit 0
fi

ENTITIES="$(mcp_call list_entities '{}')"
if [ -n "$ENTITIES" ]; then
  printf '%s' "$ENTITIES" | jq -r '
    def fmt(a): if (a|length) == 0 then "(none)"
                else [a[] | "\(.value) (\(.count))"] | join(", ") end;
    "  users    " + fmt(.users),
    "  agents   " + fmt(.agents),
    "  runs     " + fmt(.runs)' 2>/dev/null
fi

# Two lists that must be compared, not just displayed: the partitions that
# actually hold memories, and the ones this machine's config can produce. A name
# in the second but not the first is either a deliberate new partition or a typo,
# and they are indistinguishable from here — which is exactly why it is worth
# printing rather than assuming.
COUNTS="$(mcp_app_id_counts)"
RULES=""
[ -f "$ENV_FILE" ] && RULES="$(grep -E '^MEM0_SCOPE_RULES=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "\"'" || true)"
DEFAULT_APP=""
[ -f "$ENV_FILE" ] && DEFAULT_APP="$(grep -E '^MEM0_SCOPE_DEFAULT_APP=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"

RESOLVABLE="$(printf '%s\n%s\n%s\n%s\n' \
  "$MEM0_APP_ID" \
  "$(printf '%s' "$MEM0_RECALL_APP_IDS" | tr ',' '\n')" \
  "$DEFAULT_APP" \
  "$(printf '%s' "$RULES" | tr ';' '\n' | cut -d: -f1)" \
  | sed '/^[[:space:]]*$/d' | sort -u)"

printf "\n  ${DIM}app_id partitions (● holds memories · ○ empty):${NC}\n"
ALL="$(printf '%s\n%s\n' "$RESOLVABLE" "$(printf '%s' "$COUNTS" | awk '{print $2}')" \
       | sed '/^[[:space:]]*$/d' | sort -u)"
while IFS= read -r app; do
  [ -n "$app" ] || continue
  n="$(printf '%s\n' "$COUNTS" | awk -v a="$app" '$2==a {print $1; exit}')"
  n="${n:-0}"
  note=""
  [ "$app" = "$MEM0_APP_ID" ] && note=" ${BOLD}← writes go here${NC}"
  if printf '%s\n' "$RESOLVABLE" | grep -qxF "$app"; then :; else
    note="${note} ${DIM}(in the store, but no config here routes to it)${NC}"
  fi
  if [ "$n" = "0" ]; then
    printf "    ${YELLOW}○ %-20s empty — a write starts a NEW partition${NC}%b\n" "$app" "$note"
  else
    printf "    ${GREEN}● %-20s${NC} %s memories%b\n" "$app" "$n" "$note"
  fi
done <<EOF
$ALL
EOF

printf "\n  ${DIM}A partition one character off an existing one is silent: nothing errors,${NC}\n"
printf "  ${DIM}and every memory in the old one stops reaching recall.${NC}\n"
