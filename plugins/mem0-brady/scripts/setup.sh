#!/usr/bin/env bash
#
# One-time installer for the mem0-brady plugin. Run via /mem0-brady:setup.
#
# Stands up a fully local, no-Docker stack:
#   - the patched self-hosted Mem0 fork as a uv tool (OpenAI provider)
#   - a native Qdrant SERVER binary under launchd (isolated ports 6433/6434)
#   - the mem0 MCP server under launchd (HTTP on :8788), pointed at that Qdrant
#
# Both the MCP server and the SessionStart/Stop hooks connect to Qdrant over
# HTTP, so the store supports concurrent / multi-session access (an embedded
# on-disk store can't — it takes an exclusive per-process lock).
#
# Idempotent: re-running re-installs the tool, reuses an existing key, and
# re-bootstraps both launchd agents.
set -euo pipefail

# --- Pinned versions ---------------------------------------------------------
FORK_REF="v0.8.0"
FORK_URL="git+https://github.com/brady-zip/mem0-mcp-selfhosted@${FORK_REF}"
QDRANT_VERSION="v1.18.2"
# spaCy model for the 2.x native hybrid pipeline (entity extraction +
# lemmatization). Pin tracks the resolved spaCy major.minor (currently 3.8.x).
SPACY_MODEL_URL="en_core_web_sm @ https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl"

# --- Ports (isolated from a personal stack on 6333/6334/8081) ----------------
QDRANT_HTTP_PORT="6433"

# --- Paths -------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES="${SCRIPT_DIR}/templates"
CONFIG_DIR="${HOME}/.config/mem0-brady"
ENV_FILE="${CONFIG_DIR}/.env"
DATA_DIR="${HOME}/.local/share/mem0-brady"
QDRANT_BIN_DIR="${DATA_DIR}/bin"
QDRANT_BIN="${QDRANT_BIN_DIR}/qdrant"
QDRANT_STORAGE="${DATA_DIR}/qdrant-storage"
LA_DIR="${HOME}/Library/LaunchAgents"
QDRANT_LABEL="com.mem0brady.qdrant"
SERVER_LABEL="com.mem0brady.server"
QDRANT_PLIST="${LA_DIR}/${QDRANT_LABEL}.plist"
SERVER_PLIST="${LA_DIR}/${SERVER_LABEL}.plist"
QDRANT_URL="http://127.0.0.1:${QDRANT_HTTP_PORT}"
MCP_URL="http://127.0.0.1:8788/mcp"
UV_BIN="${HOME}/.local/bin"
GUI="gui/$(id -u)"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
say()  { printf "  ${GREEN}OK${NC}   %s\n" "$1"; }
warn() { printf "  ${YELLOW}WARN${NC} %s\n" "$1"; }
die()  { printf "  ${RED}FAIL${NC} %s\n" "$1" >&2; exit 1; }
step() { printf "\n${BOLD}%s${NC}\n" "$1"; }

# Return the HTTP status code for a URL, or 000 on connection failure.
# curl prints "%{http_code}" (000 on failure) AND exits non-zero, so no
# `|| echo 000` fallback — that would concatenate a second 000.
http_code() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null)"
  printf '%s' "${code:-000}"
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

# --- 1. Preflight ------------------------------------------------------------
step "1/8  Preflight"
[ "$(uname -s)" = "Darwin" ] || die "mem0-brady requires macOS (launchd). Detected: $(uname -s)"
say "macOS detected"
# Idempotent migration from the old plugin name (mem0-team): boot out any stale
# com.mem0team.* launchd agents so they don't keep :6433/:8788 bound out from
# under the new com.mem0brady.* agents. Harmless if they were never installed.
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

# --- 2. Install the fork as a uv tool ---------------------------------------
step "2/8  Install patched Mem0 fork (uv tool)"
printf "  installing %s ...\n" "${FORK_URL}"
# Pull mem0's optional dep groups so the 2.x native hybrid pipeline is live:
#   extras -> fastembed (BM25 keyword sparse vectors) + sentence-transformers
#   (the CrossEncoder reranker); nlp -> spaCy (entity extraction + lemmatization).
#   Without these, search degrades to vector-only. sentence-transformers is also
#   pinned explicitly so reranking works regardless of mem0's extras composition.
# The en_core_web_sm model is pinned as a wheel `--with` so it lands in the
# uv-managed tool venv (a `python -m spacy download` shells out to pip, which
# uv intercepts and fails). Track SPACY_MODEL_URL to spaCy's major.minor.
uv tool install --force \
  --with "mem0ai[extras,nlp]" \
  --with "sentence-transformers>=5" \
  --with "${SPACY_MODEL_URL}" \
  "${FORK_URL}" >/dev/null 2>&1 || die "uv tool install failed for ${FORK_URL}"
export PATH="${UV_BIN}:${PATH}"
for bin in mem0-mcp-selfhosted mem0-hook-context mem0-hook-stop; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin not on PATH after install (expected in ${UV_BIN})"
done
say "console scripts installed: mem0-mcp-selfhosted, mem0-hook-context, mem0-hook-stop"

# Pre-cache the reranker's CrossEncoder model so the launchd server's first boot
# doesn't block on an ~80MB HuggingFace download. The server loads the reranker
# eagerly at Memory init when MEM0_RERANK_PROVIDER is set (rendered into the .env
# below), and a cold download could blow the :8788 readiness wait in step 8.
# Cache is user-global (~/.cache/huggingface), shared with the launchd server.
# Best-effort: warn, never die — the server can still fetch it lazily.
RERANK_MODEL="cross-encoder/ms-marco-MiniLM-L-6-v2"
TOOL_PY="$(uv tool dir 2>/dev/null)/mem0-mcp-selfhosted/bin/python"
printf "  pre-caching reranker model %s ...\n" "$RERANK_MODEL"
if [ -x "$TOOL_PY" ] && "$TOOL_PY" -c "import sys; from sentence_transformers import CrossEncoder; CrossEncoder(sys.argv[1])" "$RERANK_MODEL" >/dev/null 2>&1; then
  say "reranker model cached (${RERANK_MODEL})"
else
  warn "reranker model pre-cache failed — the server will fetch it (~80MB) on first boot"
fi

# --- 3. Install the native Qdrant server binary -----------------------------
step "3/8  Install native Qdrant server (${QDRANT_VERSION}, no Docker)"
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
  TMP="$(mktemp -d)"
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

# --- 4. OpenAI key -----------------------------------------------------------
step "4/8  OpenAI API key"
EXISTING_KEY=""
if [ -f "$ENV_FILE" ]; then
  EXISTING_KEY="$(grep -E '^OPENAI_API_KEY=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
fi
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

# --- 5. Create dirs + render config -----------------------------------------
step "5/8  Config + data dirs"
mkdir -p "$CONFIG_DIR" "$QDRANT_STORAGE" "$LA_DIR"
KEY="$OPENAI_KEY" awk '{ gsub(/__OPENAI_API_KEY__/, ENVIRON["KEY"]); print }' \
  "${TEMPLATES}/env.template" > "$ENV_FILE"
chmod 600 "$ENV_FILE"
say "wrote ${ENV_FILE} (chmod 600)"
say "qdrant storage: ${QDRANT_STORAGE}"

# --- 6. Install + load the Qdrant launchd agent -----------------------------
step "6/8  launchd: ${QDRANT_LABEL}"
HOME_ESC="$HOME" awk '{ gsub(/__HOME__/, ENVIRON["HOME_ESC"]); print }' \
  "${TEMPLATES}/com.mem0brady.qdrant.plist.template" > "$QDRANT_PLIST"
say "wrote ${QDRANT_PLIST}"
load_agent "$QDRANT_LABEL" "$QDRANT_PLIST"
wait_for "${QDRANT_URL}/readyz" "Qdrant" 30

# --- 7. Install + load the mem0 MCP server launchd agent --------------------
step "7/8  launchd: ${SERVER_LABEL}"
HOME_ESC="$HOME" awk '{ gsub(/__HOME__/, ENVIRON["HOME_ESC"]); print }' \
  "${TEMPLATES}/com.mem0brady.server.plist.template" > "$SERVER_PLIST"
say "wrote ${SERVER_PLIST}"
load_agent "$SERVER_LABEL" "$SERVER_PLIST"

# --- 8. Wait for the MCP server ---------------------------------------------
step "8/8  Wait for MCP server on :8788"
wait_for "$MCP_URL" "MCP server" 30

printf "\n${GREEN}${BOLD}mem0-brady is set up.${NC}\n"
printf "  • Config:        %s\n" "$ENV_FILE"
printf "  • Qdrant:        %s (native, no Docker)\n" "$QDRANT_URL"
printf "  • Memory store:  %s (local, per-machine)\n" "$QDRANT_STORAGE"
printf "  • Logs:          %s/{qdrant,server}.log\n" "$DATA_DIR"
printf "\n${BOLD}Restart your Claude Code session${NC} so the MCP server (.mcp.json) and\n"
printf "the SessionStart/Stop hooks attach. Then run ${BLUE}/mem0-brady:doctor${NC} to verify.\n"
