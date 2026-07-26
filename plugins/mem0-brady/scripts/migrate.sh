#!/usr/bin/env bash
#
# Move a mem0-brady memory store between stacks. Run via /mem0-brady:migrate.
#
# The usual reason: a machine ran the managed stack (native Qdrant on :6433,
# collection mem0_brady, user_id shared-bch) and you want its memories in a
# shared external stack (docker-compose Qdrant, collection agent_memory,
# user_id brady) so there is only one store to maintain.
#
# Why file-based rather than Qdrant-to-Qdrant: the two stores usually live on
# different machines, each bound to its own loopback. A file crosses that gap
# over any channel you already trust, and needs no port open anywhere.
#
#   migrate.sh export <file>   # on the OLD machine
#   migrate.sh import <file>   # on the NEW machine
#   migrate.sh inspect         # what's in a store, before you commit to anything
#
# Vectors are copied VERBATIM — no re-embedding, so no OpenAI spend and no
# chance of mem0's fact-extractor rewording a memory in transit. Point IDs are
# preserved, which makes import idempotent: re-running upserts the same IDs.
# Import additionally skips any memory whose payload hash already exists in the
# target, so a partial run can be resumed safely.
#
# The source is never modified and never deleted. Rollback is repointing
# MEM0_QDRANT_URL / MEM0_COLLECTION in ~/.config/mem0-brady/.env back again.
set -euo pipefail

ENV_FILE="${MEM0_BRADY_ENV:-$HOME/.config/mem0-brady/.env}"
BATCH=64
FORMAT_VERSION=1

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
say()  { printf "  ${GREEN}OK${NC}   %s\n" "$1"; }
warn() { printf "  ${YELLOW}WARN${NC} %s\n" "$1"; }
die()  { printf "  ${RED}FAIL${NC} %s\n" "$1" >&2; exit 1; }
step() { printf "\n${BOLD}%s${NC}\n" "$1"; }
info() { printf "       %s\n" "$1"; }

# Read a KEY out of the config without sourcing it (it holds the OpenAI key).
env_get() {
  [ -f "$ENV_FILE" ] || return 0
  grep -E "^${1}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true
}

# BSD mktemp with no template ignores TMPDIR and always lands in the Darwin
# per-user temp dir, which some sandboxes deny. Always pass a template.
TMPROOT="${TMPDIR:-/tmp}"; TMPROOT="${TMPROOT%/}"
mktmp() { mktemp "${TMPROOT}/mem0-brady-migrate.XXXXXX"; }

usage() {
  cat >&2 <<EOF
Usage:
  migrate.sh export <file> [--qdrant URL] [--collection NAME] [--user-id ID]
  migrate.sh import <file> [--qdrant URL] [--collection NAME] [--user-id ID]
                           [--dry-run] [--batch N]
  migrate.sh inspect        [--qdrant URL] [--collection NAME]

Defaults come from ${ENV_FILE}. On export they describe the SOURCE, on import
the TARGET. --user-id on export filters which memories are taken; on import it
is the namespace every imported memory is rewritten to.

Examples:
  # old machine (managed stack)
  migrate.sh export ~/mem0-managed.jsonl --qdrant http://127.0.0.1:6433 \\
      --collection mem0_brady --user-id shared-bch

  # new machine (external stack), after copying the file across
  migrate.sh import ~/mem0-managed.jsonl --qdrant http://127.0.0.1:6333 \\
      --collection agent_memory --user-id brady --dry-run
EOF
  exit 2
}

# --- Arg parsing -------------------------------------------------------------
[ $# -ge 1 ] || usage
CMD="$1"; shift
FILE=""
case "$CMD" in
  export|import) [ $# -ge 1 ] || usage; FILE="$1"; shift ;;
  inspect) ;;
  -h|--help) usage ;;
  *) usage ;;
esac

OPT_QDRANT=""; OPT_COLLECTION=""; OPT_USER_ID=""; DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --qdrant)     OPT_QDRANT="${2:-}"; shift 2 ;;
    --collection) OPT_COLLECTION="${2:-}"; shift 2 ;;
    --user-id)    OPT_USER_ID="${2:-}"; shift 2 ;;
    --batch)      BATCH="${2:-64}"; shift 2 ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help)    usage ;;
    *) die "unknown option: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq not on PATH — brew install jq"
command -v curl >/dev/null 2>&1 || die "curl not on PATH"

QDRANT="${OPT_QDRANT:-$(env_get MEM0_QDRANT_URL)}"
QDRANT="${QDRANT:-http://127.0.0.1:6333}"
QDRANT="${QDRANT%/}"
COLLECTION="${OPT_COLLECTION:-$(env_get MEM0_COLLECTION)}"
COLLECTION="${COLLECTION:-mem0_brady}"
USER_ID="${OPT_USER_ID:-$(env_get MEM0_USER_ID)}"

# --- Qdrant helpers ----------------------------------------------------------
q_get() { curl -s --max-time 20 "${QDRANT}$1"; }
q_post() { curl -s --max-time 60 -X POST "${QDRANT}$1" -H 'content-type: application/json' --data-binary "$2"; }
q_put() { curl -s --max-time 60 -X PUT "${QDRANT}$1" -H 'content-type: application/json' --data-binary "$2"; }

coll_info() { q_get "/collections/$1" | jq -c 'if .result then .result else null end'; }

require_qdrant() {
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${QDRANT}/collections" 2>/dev/null || echo 000)" != "000" ] \
    || die "Qdrant not reachable at ${QDRANT}. If it runs in Docker, publish its port on the host (ports: [\"127.0.0.1:6333:6333\"])."
}

# Scroll every point of a collection to stdout as JSONL (payload + vectors).
# $1 collection, $2 optional user_id filter ("" = no filter).
scroll_all() {
  local coll="$1" uid="${2:-}" offset="null" body resp points next
  while :; do
    if [ -n "$uid" ]; then
      body="$(jq -nc --arg u "$uid" --argjson off "$offset" --argjson lim "$BATCH" \
        '{limit:$lim, with_payload:true, with_vector:true, offset:$off,
          filter:{must:[{key:"user_id", match:{value:$u}}]}}')"
    else
      body="$(jq -nc --argjson off "$offset" --argjson lim "$BATCH" \
        '{limit:$lim, with_payload:true, with_vector:true, offset:$off}')"
    fi
    resp="$(q_post "/collections/${coll}/points/scroll" "$body")"
    printf '%s' "$resp" | jq -e '.result' >/dev/null 2>&1 \
      || die "scroll failed on '${coll}': $(printf '%s' "$resp" | jq -r '.status.error // .status // "unknown error"')"
    printf '%s' "$resp" | jq -c '.result.points[]'
    next="$(printf '%s' "$resp" | jq -c '.result.next_page_offset')"
    [ "$next" = "null" ] && break
    offset="$next"
  done
}

# Collections to move: the memory collection, plus its derived <name>_entities
# sibling when one exists. Entities are extracted at write time by mem0; since
# migration writes vectors directly it bypasses that, so an un-migrated
# entities collection would silently leave graph/entity search degraded.
collections_for() {
  local base="$1"
  printf '%s\n' "$base"
  [ "$(coll_info "${base}_entities")" != "null" ] && printf '%s\n' "${base}_entities"
  return 0
}

# --- inspect -----------------------------------------------------------------
if [ "$CMD" = "inspect" ]; then
  step "Store at ${QDRANT}"
  require_qdrant
  q_get "/collections" | jq -r '.result.collections[].name' | while IFS= read -r c; do
    info_json="$(coll_info "$c")"
    printf "  %-28s %s points, %s dims\n" "$c" \
      "$(printf '%s' "$info_json" | jq -r '.points_count // 0')" \
      "$(printf '%s' "$info_json" | jq -r '.config.params.vectors.size // "?"')"
  done
  step "Namespaces in '${COLLECTION}'"
  if [ "$(coll_info "$COLLECTION")" = "null" ]; then
    warn "collection '${COLLECTION}' does not exist"
  else
    scroll_all "$COLLECTION" "" | jq -r '.payload.user_id // "(none)"' | sort | uniq -c | sort -rn \
      | while read -r n u; do printf "  %-28s %s memories\n" "$u" "$n"; done
    step "Domains (app_id) in '${COLLECTION}'"
    scroll_all "$COLLECTION" "" | jq -r '.payload.app_id // "(none)"' | sort | uniq -c | sort -rn \
      | while read -r n a; do printf "  %-28s %s memories\n" "$a" "$n"; done
  fi
  exit 0
fi

# --- export ------------------------------------------------------------------
if [ "$CMD" = "export" ]; then
  step "Export from ${QDRANT}"
  require_qdrant
  SRC_INFO="$(coll_info "$COLLECTION")"
  [ "$SRC_INFO" != "null" ] || die "collection '${COLLECTION}' not found at ${QDRANT}"
  DIMS="$(printf '%s' "$SRC_INFO" | jq -r '.config.params.vectors.size // empty')"
  say "collection '${COLLECTION}': $(printf '%s' "$SRC_INFO" | jq -r '.points_count // 0') points, ${DIMS:-?} dims"
  [ -n "$USER_ID" ] && say "filtering to user_id=${USER_ID}" || warn "no --user-id filter: exporting ALL namespaces"

  : > "$FILE"
  # Header line: lets import validate compatibility before touching the target,
  # and recreate the collection with the source's exact vector params.
  jq -nc --argjson v "$FORMAT_VERSION" --arg q "$QDRANT" --arg c "$COLLECTION" \
     --arg u "${USER_ID:-}" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     --argjson params "$(printf '%s' "$SRC_INFO" | jq -c '.config.params')" \
     '{_mem0_brady_migration:$v, exported_at:$ts, source:{qdrant:$q, collection:$c, user_id:$u}, params:$params}' \
     >> "$FILE"

  TOTAL=0
  while IFS= read -r coll; do
    n=0
    while IFS= read -r pt; do
      jq -nc --arg c "$coll" --argjson p "$pt" '{collection:$c, point:$p}' >> "$FILE"
      n=$((n + 1))
    done < <(scroll_all "$coll" "$USER_ID")
    say "exported ${n} points from '${coll}'"
    TOTAL=$((TOTAL + n))
  done < <(collections_for "$COLLECTION")

  step "Done"
  say "${TOTAL} points -> ${FILE} ($(du -h "$FILE" | cut -f1))"
  info "Copy it to the other machine, then:"
  info "  migrate.sh import ${FILE##*/} --dry-run"
  exit 0
fi

# --- import ------------------------------------------------------------------
step "Import into ${QDRANT}"
[ -f "$FILE" ] || die "no such file: ${FILE}"
require_qdrant

HEADER="$(head -1 "$FILE")"
printf '%s' "$HEADER" | jq -e '._mem0_brady_migration' >/dev/null 2>&1 \
  || die "${FILE} is not a mem0-brady export (missing header line)"
HV="$(printf '%s' "$HEADER" | jq -r '._mem0_brady_migration')"
[ "$HV" = "$FORMAT_VERSION" ] || die "export format v${HV}, this script speaks v${FORMAT_VERSION}"
SRC_COLL="$(printf '%s' "$HEADER" | jq -r '.source.collection')"
SRC_DIMS="$(printf '%s' "$HEADER" | jq -r '.params.vectors.size // empty')"
SRC_PARAMS="$(printf '%s' "$HEADER" | jq -c '.params')"
say "export from '${SRC_COLL}' at $(printf '%s' "$HEADER" | jq -r '.exported_at')"
[ -n "$USER_ID" ] || die "no target user_id — pass --user-id or set MEM0_USER_ID in ${ENV_FILE}"
say "rewriting every imported memory to user_id=${USER_ID}"

# Map source collection names onto target ones: the base collection is renamed
# to the target's, and the _entities sibling follows it.
target_for() {
  case "$1" in
    "${SRC_COLL}_entities") printf '%s_entities' "$COLLECTION" ;;
    "$SRC_COLL")            printf '%s' "$COLLECTION" ;;
    *)                      printf '%s' "$1" ;;
  esac
}

# Create/validate each target collection up front, so a dimension mismatch
# fails before any write rather than halfway through.
for src_coll in $(jq -r 'select(.collection) | .collection' "$FILE" | sort -u); do
  tgt="$(target_for "$src_coll")"
  info_json="$(coll_info "$tgt")"
  if [ "$info_json" = "null" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      say "[dry-run] would create '${tgt}' with the source's vector params"
    else
      resp="$(q_put "/collections/${tgt}" "$SRC_PARAMS")"
      printf '%s' "$resp" | jq -e '.result == true' >/dev/null 2>&1 \
        || die "could not create '${tgt}': $(printf '%s' "$resp" | jq -r '.status.error // "unknown"')"
      say "created collection '${tgt}'"
    fi
  else
    have="$(printf '%s' "$info_json" | jq -r '.config.params.vectors.size // empty')"
    [ -z "$have" ] || [ -z "$SRC_DIMS" ] || [ "$have" = "$SRC_DIMS" ] \
      || die "'${tgt}' has ${have}-dim vectors, export has ${SRC_DIMS}. Different embedding models — these stores cannot be merged."
    say "target '${tgt}' exists ($(printf '%s' "$info_json" | jq -r '.points_count // 0') points, ${have:-?} dims)"
  fi
done

# Existing payload hashes in the target, so a re-run (or a resumed partial run)
# doesn't duplicate memories that differ only by point id.
step "Scanning target for duplicates"
HASHES="$(mktmp)"; trap 'rm -f "$HASHES" "${BATCHFILE:-}"' EXIT
for src_coll in $(jq -r 'select(.collection) | .collection' "$FILE" | sort -u); do
  tgt="$(target_for "$src_coll")"
  [ "$(coll_info "$tgt")" = "null" ] && continue
  scroll_all "$tgt" "" | jq -r '.payload.hash // empty' >> "$HASHES" || true
done
sort -u -o "$HASHES" "$HASHES"
say "$(wc -l < "$HASHES" | tr -d ' ') existing memory hashes in target"

step "Importing"
BATCHFILE="$(mktmp)"
IMPORTED=0; SKIPPED=0; PENDING=0; CUR_TARGET=""
# Memories carry a content hash, so a re-run can skip them. Derived points
# (the _entities sibling) carry none — they are re-upserted under their
# original id, which overwrites rather than duplicates. Counted separately so
# a second run doesn't look like it imported 15 new things.
NEW=0; REFRESHED=0

flush() {
  [ "$PENDING" -gt 0 ] || return 0
  if [ "$DRY_RUN" = "1" ]; then
    IMPORTED=$((IMPORTED + PENDING)); PENDING=0; : > "$BATCHFILE"; return 0
  fi
  local body resp
  body="$(jq -sc '{points:.}' "$BATCHFILE")"
  resp="$(q_put "/collections/${CUR_TARGET}/points?wait=true" "$body")"
  printf '%s' "$resp" | jq -e '.result.status == "completed"' >/dev/null 2>&1 \
    || die "upsert into '${CUR_TARGET}' failed: $(printf '%s' "$resp" | jq -r '.status.error // .status // "unknown"')"
  IMPORTED=$((IMPORTED + PENDING)); PENDING=0; : > "$BATCHFILE"
}

# tail -n +2 skips the header line.
while IFS= read -r line; do
  src_coll="$(printf '%s' "$line" | jq -r '.collection')"
  tgt="$(target_for "$src_coll")"
  if [ "$tgt" != "$CUR_TARGET" ]; then flush; CUR_TARGET="$tgt"; fi

  h="$(printf '%s' "$line" | jq -r '.point.payload.hash // empty')"
  if [ -n "$h" ] && grep -qxF "$h" "$HASHES"; then
    SKIPPED=$((SKIPPED + 1)); continue
  fi
  if [ -n "$h" ]; then NEW=$((NEW + 1)); else REFRESHED=$((REFRESHED + 1)); fi
  # Rewrite the namespace, but only where the source actually carried one —
  # derived collections may have no user_id at all.
  printf '%s' "$line" | jq -c --arg u "$USER_ID" \
    '.point | if .payload.user_id then .payload.user_id = $u else . end' >> "$BATCHFILE"
  PENDING=$((PENDING + 1))
  [ "$PENDING" -ge "$BATCH" ] && flush
done < <(tail -n +2 "$FILE")
flush

step "Done"
if [ "$DRY_RUN" = "1" ]; then warn "DRY RUN — nothing was written"; fi
say "${NEW} new memories, ${SKIPPED} skipped as already present"
if [ "$REFRESHED" -gt 0 ]; then
  info "${REFRESHED} derived points (no content hash) re-upserted under their"
  info "original ids — overwrites, not duplicates. ${IMPORTED} points written in total."
fi
info "The source store was not modified. Verify with:"
info "  ${0##*/} inspect --collection ${COLLECTION}"
