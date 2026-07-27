#!/usr/bin/env bash
#
# One-time installer for the mem0-brady plugin. Run via /mem0-brady:setup.
#
# Two stacks are supported, chosen per install and recorded in the config as
# MEM0_BRADY_STACK:
#
#   managed  (default) — this plugin owns everything, no Docker:
#       - the vendored self-hosted Mem0 server (../server) as a uv tool
#       - a native Qdrant SERVER binary under launchd (isolated ports 6433/6434)
#       - the mem0 MCP server under launchd, pointed at that Qdrant
#
#   external — you already run Qdrant + the mem0 MCP server (e.g. docker-compose).
#       The hooks then drive mem0 THROUGH that server, so this host needs no
#       Qdrant reachability, no API key, no store identity and no mem0 install
#       — the server owns all of it. Setup writes a two-line config and a small
#       MCP-only tool install. No Qdrant binary, no launchd agents.
#
# For a managed stack, store identity (collection / user_id / URLs) is
# per-INSTALL, prompted here and stored in the config — never baked into the
# plugin. Point two machines at the same values and they share one memory.
#
# On a MANAGED stack the server and the hooks both connect to Qdrant over HTTP,
# so the store supports concurrent / multi-session access (an embedded on-disk
# store can't — it takes an exclusive per-process lock). On an external stack
# the hooks reach Qdrant only through the server, so the host never needs it.
#
# Idempotent: re-running re-installs the tool, MERGES (never clobbers) the
# config, and re-bootstraps the launchd agents it owns.
set -euo pipefail

# --- Pinned versions ---------------------------------------------------------
# The mem0 MCP server is vendored into this plugin at ../server (installed from
# that local source below), so there is no GitHub pin to track anymore.
QDRANT_VERSION="v1.18.2"
# spaCy model for the 2.x native hybrid pipeline (entity extraction +
# lemmatization). Pin tracks the resolved spaCy major.minor (currently 3.8.x).
SPACY_MODEL_URL="en_core_web_sm @ https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl"

# --- Managed-stack defaults (isolated from a personal stack on 6333/6334/8081) -
DEFAULT_QDRANT_HTTP_PORT="6433"
DEFAULT_QDRANT_GRPC_PORT="6434"
DEFAULT_MCP_PORT="8788"
DEFAULT_COLLECTION="mem0_brady"
DEFAULT_USER_ID="shared-bch"

# --- Paths -------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES="${SCRIPT_DIR}/templates"
# The vendored mem0 MCP server source lives beside scripts/ inside the plugin.
# Resolves for both `--plugin-dir` local iteration and the marketplace cache
# path (~/.claude/plugins/cache/bradys-marketplace/mem0-brady/<version>/server).
SERVER_DIR="$(cd "${SCRIPT_DIR}/../server" && pwd)"
# Overridable so the config can be relocated, and so the installer is testable
# without writing to a real home. doctor.sh / migrate.sh / the hooks already
# honor MEM0_BRADY_ENV; setup was the one place that didn't.
CONFIG_DIR="${MEM0_BRADY_CONFIG_DIR:-${HOME}/.config/mem0-brady}"
ENV_FILE="${MEM0_BRADY_ENV:-${CONFIG_DIR}/.env}"
DATA_DIR="${MEM0_BRADY_DATA_DIR:-${HOME}/.local/share/mem0-brady}"
QDRANT_BIN_DIR="${DATA_DIR}/bin"
QDRANT_BIN="${QDRANT_BIN_DIR}/qdrant"
QDRANT_STORAGE="${DATA_DIR}/qdrant-storage"
LA_DIR="${HOME}/Library/LaunchAgents"
QDRANT_LABEL="com.mem0brady.qdrant"
SERVER_LABEL="com.mem0brady.server"
QDRANT_PLIST="${LA_DIR}/${QDRANT_LABEL}.plist"
SERVER_PLIST="${LA_DIR}/${SERVER_LABEL}.plist"
UV_BIN="${HOME}/.local/bin"
GUI="gui/$(id -u)"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
say()  { printf "  ${GREEN}OK${NC}   %s\n" "$1"; }
warn() { printf "  ${YELLOW}WARN${NC} %s\n" "$1"; }
die()  { printf "  ${RED}FAIL${NC} %s\n" "$1" >&2; exit 1; }
step() { printf "\n${BOLD}%s${NC}\n" "$1"; }

# BSD mktemp with no template ignores TMPDIR and always lands in the Darwin
# per-user temp dir, which some sandboxes deny. Always pass a template.
TMPROOT="${TMPDIR:-/tmp}"; TMPROOT="${TMPROOT%/}"
mktmp()  { mktemp "${TMPROOT}/mem0-brady-setup.XXXXXX"; }
mktmpd() { mktemp -d "${TMPROOT}/mem0-brady-setup.XXXXXX"; }

# Return the HTTP status code for a URL, or 000 on connection failure.
# curl prints "%{http_code}" (000 on failure) AND exits non-zero, so no
# `|| echo 000` fallback — that would concatenate a second 000.
http_code() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null)"
  printf '%s' "${code:-000}"
}

# Read a single KEY's value out of an env file, without sourcing it (the file
# holds the OpenAI key; sourcing would leak it into this shell's exported env
# and into any child process).
env_get() {
  local key="$1" file="$2"
  [ -f "$file" ] || return 0
  grep -E "^${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2- || true
}

# Prompt with a default. Honors MEM0_BRADY_NONINTERACTIVE=1 (takes the default)
# so the installer can run unattended in a provisioning script.
ask() {
  local prompt="$1" default="$2" reply
  if [ "${MEM0_BRADY_NONINTERACTIVE:-0}" = "1" ] || [ ! -t 0 ]; then
    printf '%s' "$default"; return 0
  fi
  printf "  %s [%s]: " "$prompt" "$default" >&2
  read -r reply
  printf '%s' "${reply:-$default}"
}

# bootout (ignore "not loaded"), wait for the job to fully unload, then
# bootstrap with retries. `bootout` is ASYNC: bootstrapping before the old job
# has finished tearing down races it and fails ("Input/output error"), and the
# kickstart fallback then fails too because nothing is loaded yet — which is how
# a re-run against an already-running stack used to leave the service down.
# Polling until the job is gone + retrying bootstrap makes re-runs reliable.
load_agent() {
  local label="$1" plist="$2" i
  launchctl bootout "${GUI}/${label}" >/dev/null 2>&1 || true
  # wait until the old job is actually gone (up to ~5s)
  for i in $(seq 1 10); do
    launchctl print "${GUI}/${label}" >/dev/null 2>&1 || break
    sleep 0.5
  done
  # retry bootstrap a few times; the unload may still be settling
  for i in $(seq 1 5); do
    if launchctl bootstrap "$GUI" "$plist" 2>/dev/null; then
      say "bootstrapped ${label}"
      return 0
    fi
    sleep 1
  done
  # last resort: kickstart if it happens to be loaded
  launchctl kickstart -k "${GUI}/${label}" >/dev/null 2>&1 \
    && say "kickstarted ${label}" \
    || die "could not load ${label} — check logs under ${DATA_DIR}"
}

# Poll a URL until it answers (non-000) or times out.
wait_for() {
  local url="$1" label="$2" attempts="${3:-30}" i code
  for i in $(seq 1 "$attempts"); do
    code="$(http_code "$url")"
    if [ "$code" != "000" ]; then say "${label} reachable at ${url} (HTTP ${code})"; return 0; fi
    sleep 1
  done
  die "${label} not reachable at ${url} after ${attempts}s — check logs under ${DATA_DIR}"
}

# --- Preflight ---------------------------------------------------------------
step "Preflight"
[ "$(uname -s)" = "Darwin" ] || die "mem0-brady requires macOS (launchd). Detected: $(uname -s)"
say "macOS detected"
# Idempotent migration from the old plugin name (mem0-team): boot out any stale
# com.mem0team.* launchd agents so they don't keep the managed ports bound out
# from under the new com.mem0brady.* agents. Harmless if never installed.
for stale in com.mem0team.server com.mem0team.qdrant; do
  if launchctl print "${GUI}/${stale}" >/dev/null 2>&1; then
    launchctl bootout "${GUI}/${stale}" >/dev/null 2>&1 || true
    rm -f "${LA_DIR}/${stale}.plist" 2>/dev/null || true
    say "removed stale agent ${stale} (old mem0-team plugin)"
  fi
done
for tool in curl jq tar; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not on PATH — install with: brew install $tool"
done
say "curl + jq + tar present"
if ! command -v uv >/dev/null 2>&1; then
  warn "uv not found — installing via astral.sh"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="${UV_BIN}:${HOME}/.cargo/bin:${PATH}"
  command -v uv >/dev/null 2>&1 || die "uv install failed — install manually: https://docs.astral.sh/uv/"
fi
say "uv present ($(command -v uv))"

# --- Stack + identity --------------------------------------------------------
# Every value is resolved in the same precedence order:
#   explicit env var  >  existing config  >  interactive prompt (default)
# so a re-run is silent and non-destructive, while a first run is a short
# interview. Nothing here is baked into the plugin.
step "Stack + store identity"
STACK="${MEM0_BRADY_STACK:-$(env_get MEM0_BRADY_STACK "$ENV_FILE")}"
if [ -z "$STACK" ]; then
  printf "  Which stack backs this install?\n"
  printf "    managed  — this plugin runs Qdrant + the MCP server under launchd (no Docker)\n"
  printf "    external — you already run Qdrant + the MCP server yourself\n"
  STACK="$(ask "stack (managed/external)" "managed")"
fi
case "$STACK" in
  managed|external) say "stack: ${STACK}" ;;
  *) die "MEM0_BRADY_STACK must be 'managed' or 'external' (got '${STACK}')" ;;
esac

# An external stack talks MCP, which is what makes the rest of this section
# unnecessary there: the server already holds every value it would ask for.
MCP_MODE=0
[ "$STACK" = "external" ] && MCP_MODE=1

QDRANT_HTTP_PORT="$(env_get MEM0_BRADY_QDRANT_HTTP_PORT "$ENV_FILE")"
QDRANT_HTTP_PORT="${QDRANT_HTTP_PORT:-$DEFAULT_QDRANT_HTTP_PORT}"
QDRANT_GRPC_PORT="$(env_get MEM0_BRADY_QDRANT_GRPC_PORT "$ENV_FILE")"
QDRANT_GRPC_PORT="${QDRANT_GRPC_PORT:-$DEFAULT_QDRANT_GRPC_PORT}"

if [ "$STACK" = "managed" ]; then
  DEF_QDRANT_URL="http://127.0.0.1:${QDRANT_HTTP_PORT}"
  DEF_MCP_PORT="$DEFAULT_MCP_PORT"
  DEF_MCP_URL="http://127.0.0.1:${DEFAULT_MCP_PORT}/mcp"
else
  # An external stack is most often a docker-compose one publishing the stock
  # Qdrant port on loopback, with the MCP server on the fork's default 8081.
  DEF_QDRANT_URL="http://127.0.0.1:6333"
  DEF_MCP_PORT="8081"
  DEF_MCP_URL="http://127.0.0.1:8081/mcp"
fi

MCP_URL="${MEM0_BRADY_MCP_URL:-$(env_get MEM0_BRADY_MCP_URL "$ENV_FILE")}"
[ -n "$MCP_URL" ] || MCP_URL="$(ask "mem0 MCP URL (what clients connect to)" "$DEF_MCP_URL")"

if [ "$MCP_MODE" = "1" ]; then
  say "mcp=${MCP_URL}"
  say "store identity, embeddings and API key: owned by the server, not configured here"
else
  QDRANT_URL="${MEM0_BRADY_QDRANT_URL:-$(env_get MEM0_QDRANT_URL "$ENV_FILE")}"
  [ -n "$QDRANT_URL" ] || QDRANT_URL="$(ask "Qdrant URL" "$DEF_QDRANT_URL")"
  MCP_PORT="$(env_get MEM0_PORT "$ENV_FILE")"
  MCP_PORT="${MCP_PORT:-$DEF_MCP_PORT}"
  COLLECTION="${MEM0_BRADY_COLLECTION:-$(env_get MEM0_COLLECTION "$ENV_FILE")}"
  [ -n "$COLLECTION" ] || COLLECTION="$(ask "Qdrant collection" "$DEFAULT_COLLECTION")"
  USER_ID="${MEM0_BRADY_USER_ID:-$(env_get MEM0_USER_ID "$ENV_FILE")}"
  [ -n "$USER_ID" ] || USER_ID="$(ask "shared user_id (the namespace every actor reads)" "$DEFAULT_USER_ID")"
  say "identity: collection=${COLLECTION} user_id=${USER_ID}"
  say "qdrant=${QDRANT_URL}  mcp=${MCP_URL}"
fi

# --- Guard: don't silently strand a managed store ----------------------------
# Switching an install that already has managed-stack memories over to an
# external store leaves those vectors behind with no pointer to them. Refuse,
# and name the way out. MEM0_BRADY_ALLOW_STRANDED=1 is the deliberate override.
if [ "$STACK" = "external" ] && [ "${MEM0_BRADY_ALLOW_STRANDED:-0}" != "1" ]; then
  stranded=""
  if [ -d "$QDRANT_STORAGE" ] && find "$QDRANT_STORAGE" -mindepth 1 -maxdepth 1 2>/dev/null | grep -q .; then
    stranded="storage dir ${QDRANT_STORAGE} is non-empty"
  fi
  if [ "$(http_code "http://127.0.0.1:${QDRANT_HTTP_PORT}/collections")" != "000" ]; then
    stranded="${stranded:+${stranded}; }a managed Qdrant is answering on :${QDRANT_HTTP_PORT}"
  fi
  if [ -n "$stranded" ]; then
    printf "\n  ${RED}FAIL${NC} refusing to switch to an external stack: %s\n" "$stranded" >&2
    printf "        Those memories would be left behind. Move them first:\n" >&2
    printf "          ${BLUE}%s/migrate.sh export ~/mem0-managed.jsonl${NC}\n" "$SCRIPT_DIR" >&2
    printf "          ${BLUE}%s/migrate.sh import ~/mem0-managed.jsonl${NC}\n" "$SCRIPT_DIR" >&2
    printf "        Or re-run with MEM0_BRADY_ALLOW_STRANDED=1 to proceed anyway.\n" >&2
    exit 1
  fi
  say "no managed-stack data to strand"
fi

# --- Install the vendored server as a uv tool --------------------------------
step "Install vendored Mem0 server (uv tool)"
[ -f "${SERVER_DIR}/pyproject.toml" ] || die "vendored server not found at ${SERVER_DIR} (expected pyproject.toml)"
printf "  installing from %s ...\n" "${SERVER_DIR}"
# Pull mem0's optional dep groups so the 2.x native hybrid pipeline is live:
#   extras -> fastembed (BM25 keyword sparse vectors) + sentence-transformers
#   (the CrossEncoder reranker); nlp -> spaCy (entity extraction + lemmatization).
#   Without these, search degrades to vector-only. sentence-transformers is also
#   pinned explicitly so reranking works regardless of mem0's extras composition.
# The en_core_web_sm model is pinned as a wheel `--with` so it lands in the
# uv-managed tool venv (a `python -m spacy download` shells out to pip, which
# uv intercepts and fails). Track SPACY_MODEL_URL to spaCy's major.minor.
if [ "$MCP_MODE" = "1" ]; then
  # MCP mode drives mem0 through the server, so the hooks never import mem0 —
  # skip the `direct` extra and every model dependency behind it. This is the
  # difference between a ~70MB install and a multi-GB one.
# --reinstall (implies --refresh) is load-bearing, not belt-and-braces: the
# vendored source is a PATH dependency whose version rarely changes while its
# contents change constantly. Plain --force replaces the tool but reuses uv's
# cached build for the same path+version, so editing the fork and re-running
# setup silently reinstalls the OLD code — observed shipping a stale
# mcp_client.py that wrote memories to the wrong namespace.
  uv tool install --force --reinstall "${SERVER_DIR}" >/dev/null 2>&1 \
    || die "uv tool install failed for ${SERVER_DIR}"
else
  uv tool install --force --reinstall \
    --with "mem0ai[extras,nlp]" \
    --with "sentence-transformers>=5" \
    --with "${SPACY_MODEL_URL}" \
    "${SERVER_DIR}[direct]" >/dev/null 2>&1 || die "uv tool install failed for ${SERVER_DIR}"
fi
export PATH="${UV_BIN}:${PATH}"
for bin in mem0-mcp-selfhosted mem0-hook-context mem0-hook-stop; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin not on PATH after install (expected in ${UV_BIN})"
done
say "console scripts installed: mem0-mcp-selfhosted, mem0-hook-context, mem0-hook-stop"

# Pre-cache the reranker's CrossEncoder model so the launchd server's first boot
# doesn't block on an ~80MB HuggingFace download. The server loads the reranker
# eagerly at Memory init when MEM0_RERANK_PROVIDER is set (rendered into the .env
# below), and a cold download could blow the readiness wait at the end.
# Cache is user-global (~/.cache/huggingface), shared with the launchd server.
# Best-effort: warn, never die — the server can still fetch it lazily.
if [ "$MCP_MODE" = "1" ]; then
  say "skipping reranker pre-cache — the server does its own retrieval"
else
RERANK_MODEL="cross-encoder/ms-marco-MiniLM-L-6-v2"
TOOL_PY="$(uv tool dir 2>/dev/null)/mem0-mcp-selfhosted/bin/python"
printf "  pre-caching reranker model %s ...\n" "$RERANK_MODEL"
if [ -x "$TOOL_PY" ] && "$TOOL_PY" -c "import sys; from sentence_transformers import CrossEncoder; CrossEncoder(sys.argv[1])" "$RERANK_MODEL" >/dev/null 2>&1; then
  say "reranker model cached (${RERANK_MODEL})"
else
  warn "reranker model pre-cache failed — the server will fetch it (~80MB) on first boot"
fi
fi

# --- Install the native Qdrant server binary (managed only) ------------------
if [ "$STACK" = "managed" ]; then
  step "Install native Qdrant server (${QDRANT_VERSION}, no Docker)"
  ARCH="$(uname -m)"
  case "$ARCH" in
    arm64|aarch64) QASSET="qdrant-aarch64-apple-darwin.tar.gz" ;;
    x86_64)        QASSET="qdrant-x86_64-apple-darwin.tar.gz" ;;
    *) die "unsupported CPU arch: ${ARCH}" ;;
  esac
  mkdir -p "$QDRANT_BIN_DIR"
  if [ -x "$QDRANT_BIN" ] && "$QDRANT_BIN" --version >/dev/null 2>&1; then
    say "qdrant already installed ($("$QDRANT_BIN" --version 2>/dev/null | head -1))"
  else
    QURL="https://github.com/qdrant/qdrant/releases/download/${QDRANT_VERSION}/${QASSET}"
    printf "  downloading %s ...\n" "$QURL"
    TMP="$(mktmpd)"
    curl -LsSf "$QURL" -o "${TMP}/qdrant.tar.gz" || die "qdrant download failed: ${QURL}"
    tar -xzf "${TMP}/qdrant.tar.gz" -C "$TMP" || die "qdrant extract failed"
    # The tarball contains a single `qdrant` binary at its root.
    QSRC="$(find "$TMP" -type f -name qdrant -perm -u+x 2>/dev/null | head -1)"
    [ -n "$QSRC" ] || QSRC="${TMP}/qdrant"
    [ -f "$QSRC" ] || die "qdrant binary not found in tarball"
    install -m 0755 "$QSRC" "$QDRANT_BIN"
    rm -rf "$TMP"
    say "installed qdrant -> ${QDRANT_BIN} ($("$QDRANT_BIN" --version 2>/dev/null | head -1))"
  fi
else
  step "Native Qdrant server"
  say "skipped — external stack (you run Qdrant yourself)"
fi

# --- OpenAI key --------------------------------------------------------------
step "OpenAI API key"
OPENAI_KEY=""
if [ "$MCP_MODE" = "1" ]; then
  say "not needed — the server owns the key (embeddings, extraction, synthesis)"
else
EXISTING_KEY="$(env_get OPENAI_API_KEY "$ENV_FILE")"
if [ -n "$EXISTING_KEY" ] && [ "$EXISTING_KEY" != "__OPENAI_API_KEY__" ]; then
  say "reusing existing key from ${ENV_FILE}"
  OPENAI_KEY="$EXISTING_KEY"
else
  printf "  Enter your OpenAI API key (input hidden): "
  read -rs OPENAI_KEY
  printf "\n"
  [ -n "$OPENAI_KEY" ] || die "no key entered"
  case "$OPENAI_KEY" in
    sk-*) say "key captured" ;;
    *) die "that doesn't look like an OpenAI key (expected to start with 'sk-')" ;;
  esac
fi
fi

# --- Create dirs + merge config ----------------------------------------------
step "Config + data dirs"
mkdir -p "$CONFIG_DIR" "$LA_DIR"
[ "$STACK" = "managed" ] && mkdir -p "$QDRANT_STORAGE"

RENDERED="$(mktmp)"
trap 'rm -f "$RENDERED"' EXIT
# MCP mode has its own, deliberately tiny template: every value the managed one
# carries is owned by the server, and a stale duplicate here would fail by
# quietly reading a different store.
if [ "$MCP_MODE" = "1" ]; then
  TEMPLATE="${TEMPLATES}/env.external.template"
else
  TEMPLATE="${TEMPLATES}/env.template"
fi
# Unset in MCP mode — the external template has no placeholders for them, but
# the awk call below still expands the variables, and `set -u` would abort.
COLLECTION="${COLLECTION:-}"; USER_ID="${USER_ID:-}"
QDRANT_URL="${QDRANT_URL:-}"; MCP_PORT="${MCP_PORT:-}"
KEY="$OPENAI_KEY" STACK_V="$STACK" COLLECTION_V="$COLLECTION" USER_ID_V="$USER_ID" \
QDRANT_URL_V="$QDRANT_URL" MCP_URL_V="$MCP_URL" MCP_PORT_V="$MCP_PORT" \
QHTTP_V="$QDRANT_HTTP_PORT" QGRPC_V="$QDRANT_GRPC_PORT" \
awk '{
  gsub(/__OPENAI_API_KEY__/,     ENVIRON["KEY"]);
  gsub(/__STACK__/,              ENVIRON["STACK_V"]);
  gsub(/__COLLECTION__/,         ENVIRON["COLLECTION_V"]);
  gsub(/__USER_ID__/,            ENVIRON["USER_ID_V"]);
  gsub(/__QDRANT_URL__/,         ENVIRON["QDRANT_URL_V"]);
  gsub(/__MCP_URL__/,            ENVIRON["MCP_URL_V"]);
  gsub(/__MCP_PORT__/,           ENVIRON["MCP_PORT_V"]);
  gsub(/__QDRANT_HTTP_PORT__/,   ENVIRON["QHTTP_V"]);
  gsub(/__QDRANT_GRPC_PORT__/,   ENVIRON["QGRPC_V"]);
  print
}' "$TEMPLATE" > "$RENDERED"

if [ -f "$ENV_FILE" ]; then
  # MERGE, never clobber. Values resolved above already reflect the existing
  # file (env_get) or an explicit override, so rewrite exactly the keys we
  # manage, leave every other line — including your comments and any key the
  # template doesn't know about — untouched, and append keys that are new in
  # this plugin version. Losing a hand-tuned config to an upgrade is the whole
  # bug this replaces.
  MERGED="$(mktmp)"
  cp "$ENV_FILE" "$MERGED"
  # Only keys the CHOSEN template defines are rewritten, so switching a managed
  # install to external leaves its old identity keys in place, inert, rather
  # than deleting values you may still want if you switch back.
  for k in MEM0_BRADY_STACK MEM0_COLLECTION MEM0_USER_ID MEM0_QDRANT_URL \
           MEM0_BRADY_MCP_URL MEM0_PORT MEM0_BRADY_QDRANT_HTTP_PORT \
           MEM0_BRADY_QDRANT_GRPC_PORT OPENAI_API_KEY; do
    newline="$(grep -E "^${k}=" "$RENDERED" | head -1 || true)"
    [ -n "$newline" ] || continue
    if grep -qE "^${k}=" "$MERGED"; then
      # Rewrite in place via awk (sed would mangle URLs and base64-ish keys).
      TMP2="$(mktmp)"
      K="$k" LINE="$newline" awk '
        $0 ~ "^" ENVIRON["K"] "=" && !done { print ENVIRON["LINE"]; done=1; next }
        { print }
      ' "$MERGED" > "$TMP2" && mv "$TMP2" "$MERGED"
    else
      printf '%s\n' "$newline" >> "$MERGED"
    fi
  done
  # Append any template key entirely absent from the user's file (new in an upgrade).
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    k="${line%%=*}"
    grep -qE "^${k}=" "$MERGED" || printf '%s\n' "$line" >> "$MERGED"
  done < "$RENDERED"
  mv "$MERGED" "$ENV_FILE"
  say "merged ${ENV_FILE} (existing values preserved)"
else
  cp "$RENDERED" "$ENV_FILE"
  say "wrote ${ENV_FILE}"
fi
chmod 600 "$ENV_FILE"
say "permissions 600"
[ "$STACK" = "managed" ] && say "qdrant storage: ${QDRANT_STORAGE}"

# --- launchd agents (managed only) -------------------------------------------
if [ "$STACK" = "managed" ]; then
  step "launchd: ${QDRANT_LABEL}"
  HOME_ESC="$HOME" QHTTP_V="$QDRANT_HTTP_PORT" QGRPC_V="$QDRANT_GRPC_PORT" awk '{
    gsub(/__HOME__/,              ENVIRON["HOME_ESC"]);
    gsub(/__QDRANT_HTTP_PORT__/,  ENVIRON["QHTTP_V"]);
    gsub(/__QDRANT_GRPC_PORT__/,  ENVIRON["QGRPC_V"]);
    print
  }' "${TEMPLATES}/com.mem0brady.qdrant.plist.template" > "$QDRANT_PLIST"
  say "wrote ${QDRANT_PLIST}"
  load_agent "$QDRANT_LABEL" "$QDRANT_PLIST"
  wait_for "http://127.0.0.1:${QDRANT_HTTP_PORT}/readyz" "Qdrant" 30

  step "launchd: ${SERVER_LABEL}"
  HOME_ESC="$HOME" awk '{ gsub(/__HOME__/, ENVIRON["HOME_ESC"]); print }' \
    "${TEMPLATES}/com.mem0brady.server.plist.template" > "$SERVER_PLIST"
  say "wrote ${SERVER_PLIST}"
  load_agent "$SERVER_LABEL" "$SERVER_PLIST"
else
  step "launchd agents"
  say "skipped — external stack (you run the MCP server yourself)"
  # The hooks reach mem0 only through the server now, so the server — not
  # Qdrant — is what has to answer from this shell.
  if [ "$(http_code "$MCP_URL")" = "000" ]; then
    printf "  ${RED}FAIL${NC} the mem0 MCP server is not reachable at %s.\n" "$MCP_URL" >&2
    printf "        Start your external stack, then re-run. Everything else this\n" >&2
    printf "        install needs — Qdrant, the store identity, the API key — lives\n" >&2
    printf "        behind that server and is never contacted from here.\n" >&2
    exit 1
  fi
  say "mem0 MCP server reachable at ${MCP_URL}"
fi

# --- Verify the store matches this config ------------------------------------
# A collection is created with a fixed vector size; pointing a differently
# configured install at it yields confusing runtime errors deep inside mem0.
# Catch it here, where the fix is obvious.
step "Verify store"
if [ "$MCP_MODE" = "1" ]; then
  say "skipped — the server owns the collection and validates it itself"
else
COLL_JSON="$(curl -s --max-time 5 "${QDRANT_URL}/collections/${COLLECTION}" 2>/dev/null || true)"
if printf '%s' "$COLL_JSON" | jq -e '.result' >/dev/null 2>&1; then
  HAVE_DIMS="$(printf '%s' "$COLL_JSON" | jq -r '.result.config.params.vectors.size // empty')"
  POINTS="$(printf '%s' "$COLL_JSON" | jq -r '.result.points_count // 0')"
  WANT_DIMS="$(grep -E '^MEM0_EMBED_DIMS=' "$ENV_FILE" | head -1 | cut -d= -f2-)"
  if [ -n "$HAVE_DIMS" ] && [ -n "$WANT_DIMS" ] && [ "$HAVE_DIMS" != "$WANT_DIMS" ]; then
    die "collection '${COLLECTION}' has ${HAVE_DIMS}-dim vectors but MEM0_EMBED_DIMS=${WANT_DIMS}. Use a different collection, or migrate."
  fi
  say "collection '${COLLECTION}' exists (${POINTS} memories, ${HAVE_DIMS:-?} dims)"
else
  say "collection '${COLLECTION}' does not exist yet — created on first write"
fi
fi

# --- Wait for the MCP server -------------------------------------------------
step "Wait for MCP server"
if [ "$STACK" = "managed" ]; then
  wait_for "$MCP_URL" "MCP server" 30
else
  if [ "$(http_code "$MCP_URL")" = "000" ]; then
    warn "MCP server not reachable at ${MCP_URL} — start your external stack, then re-check with /mem0-brady:doctor"
  else
    say "MCP server reachable at ${MCP_URL}"
  fi
fi

# --- Memory scopes -----------------------------------------------------------
step "Memory scopes"
# Runs LAST, after the server is up, for one reason: it shows which partitions
# already hold memories before asking you to name one. Choosing a partition
# blind is how you end up one character off an existing name — nothing errors,
# the write starts a fresh partition, and every memory in the old one silently
# stops reaching recall.
#
# Writes real (uncommented) keys rather than relying on the template merge: the
# template documents these keys in comments, and the merge loop skips comment
# lines, so an existing install would otherwise never receive them.
# shellcheck source=lib-mcp.sh
. "${SCRIPT_DIR}/lib-mcp.sh"

say "app_id partitions work; agent_id is who writes them; run_id is the active workstream."
if mcp_init "$MCP_URL"; then
  COUNTS="$(mcp_app_id_counts)"
  if [ -n "$COUNTS" ]; then
    say "partitions already in this store:"
    printf '%s\n' "$COUNTS" | while read -r n a; do printf "    %-24s %s memories\n" "$a" "$n"; done
    say "reuse a name above to ATTACH to existing memories; a new name starts an empty partition"
  else
    say "this store holds no memories yet — any partition name starts fresh"
  fi
else
  warn "could not read the store (server unreachable) — naming a partition here is unverified"
fi

EXIST_RULES="$(env_get MEM0_SCOPE_RULES "$ENV_FILE")"
EXIST_DEFAULT="$(env_get MEM0_SCOPE_DEFAULT_APP "$ENV_FILE")"
EXIST_AGENT="$(env_get MEM0_SCOPE_AGENT_ID "$ENV_FILE")"

SCOPE_DEFAULT_APP="$(ask "default app_id for paths matching no rule" "${EXIST_DEFAULT:-general}")"
SCOPE_AGENT="$(ask "agent_id for sessions on this machine" "${EXIST_AGENT:-claude}")"
say "routing rules map a path glob to an app_id, e.g. 'evergreen:*evergreen*;hal-ops:*/hal/*'"
say "leave blank to route everything to '${SCOPE_DEFAULT_APP}' (per-repo overrides still work)"
SCOPE_RULES="$(ask "MEM0_SCOPE_RULES" "$(printf '%s' "${EXIST_RULES}" | tr -d "\"'")")"

# Always single-quote the rules on write. The value is globs joined by ';' in a
# file that gets sourced, so unquoted it does not merely misparse: the ';' ends
# the assignment and the shell tries to run the remainder.
set_env_key() {
  local k="$1" v="$2" line tmp
  line="${k}=${v}"
  if grep -qE "^${k}=" "$ENV_FILE" 2>/dev/null; then
    tmp="$(mktmp)"
    K="$k" LINE="$line" awk '
      $0 ~ "^" ENVIRON["K"] "=" && !done { print ENVIRON["LINE"]; done=1; next }
      { print }' "$ENV_FILE" > "$tmp" && mv "$tmp" "$ENV_FILE"
  else
    printf '%s\n' "$line" >> "$ENV_FILE"
  fi
}
set_env_key MEM0_SCOPE_DEFAULT_APP "$SCOPE_DEFAULT_APP"
set_env_key MEM0_SCOPE_AGENT_ID "$SCOPE_AGENT"
[ -n "$SCOPE_RULES" ] && set_env_key MEM0_SCOPE_RULES "'${SCOPE_RULES}'"
chmod 600 "$ENV_FILE"
say "scopes written to ${ENV_FILE}"

# Per-repo override. Offered only when the cwd is a checkout that does not
# already have one — a repo whose memories belong in their own partition says so
# in its own tree, so the routing travels with a clone instead of living only in
# one machine's config.
REPO_ROOT="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$REPO_ROOT" ] && [ ! -f "${REPO_ROOT}/.mem0-brady.json" ]; then
  REPO_APP="$(ask "app_id for the repo at ${REPO_ROOT} (blank to skip)" "")"
  if [ -n "$REPO_APP" ]; then
    printf '{\n  "app_id": "%s",\n  "recall_app_ids": ["%s", "%s"]\n}\n' \
      "$REPO_APP" "$REPO_APP" "$SCOPE_DEFAULT_APP" > "${REPO_ROOT}/.mem0-brady.json"
    say "wrote ${REPO_ROOT}/.mem0-brady.json (recall spans ${REPO_APP} + ${SCOPE_DEFAULT_APP})"
  fi
fi
say "run /mem0-brady:scopes to see what any directory resolves to, and why"

printf "\n${GREEN}${BOLD}mem0-brady is set up.${NC}\n"
printf "  • Stack:         %s\n" "$STACK"
printf "  • Config:        %s\n" "$ENV_FILE"
printf "  • MCP server:    %s\n" "$MCP_URL"
if [ "$MCP_MODE" = "1" ]; then
  # QDRANT_URL / COLLECTION / USER_ID are never set in this mode — the server
  # owns them, and under `set -u` printing them would abort the run.
  printf "  • Qdrant:        via the server (not contacted from this host)\n"
  printf "  • Store:         owned by the server\n"
  printf "  • Install:       MCP client only — no mem0, no models, no API key\n"
else
  printf "  • Qdrant:        %s\n" "$QDRANT_URL"
  printf "  • Store:         collection %s, user_id %s\n" "$COLLECTION" "$USER_ID"
fi
if [ "$STACK" = "managed" ]; then
  printf "  • Memory store:  %s (local, per-machine)\n" "$QDRANT_STORAGE"
  printf "  • Logs:          %s/{qdrant,server}.log\n" "$DATA_DIR"
fi
printf "\n${BOLD}Register the MCP at the user level${NC} (once per machine), so the\n"
printf "canonical mcp__mem0__* tool namespace exists in every project:\n"
printf "  ${BLUE}claude mcp add --transport http --scope user mem0 %s${NC}\n" "$MCP_URL"
printf "\n${BOLD}Restart your Claude Code session${NC} so the MCP server and the\n"
printf "SessionStart/Stop hooks attach. Then run ${BLUE}/mem0-brady:doctor${NC} to verify.\n"
