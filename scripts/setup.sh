#!/usr/bin/env bash
#
# One-time installer for the mem0-brady plugin. Run via /mem0-brady:setup.
#
# Stands up a fully local, no-Docker stack:
#   - the patched self-hosted Mem0 fork as a uv tool (OpenAI LLM; OpenAI or
#     ZeroEntropy for embeddings + reranking — setup asks which)
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
FORK_REF="v0.6.1"
FORK_URL="git+https://github.com/brady-zip/mem0-mcp-selfhosted@${FORK_REF}"
QDRANT_VERSION="v1.18.2"

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

# bootout (ignore "not loaded") then bootstrap a launchd agent; fall back to
# kickstart if bootstrap reports it is already loaded.
load_agent() {
  local label="$1" plist="$2"
  launchctl bootout "${GUI}/${label}" >/dev/null 2>&1 || true
  if launchctl bootstrap "$GUI" "$plist" 2>/dev/null; then
    say "bootstrapped ${label}"
  else
    launchctl kickstart -k "${GUI}/${label}" >/dev/null 2>&1 \
      && say "kickstarted ${label}" \
      || die "could not load ${label} — check logs under ${DATA_DIR}"
  fi
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
uv tool install --force "${FORK_URL}" >/dev/null 2>&1 || die "uv tool install failed for ${FORK_URL}"
export PATH="${UV_BIN}:${PATH}"
for bin in mem0-mcp-selfhosted mem0-hook-context mem0-hook-stop; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin not on PATH after install (expected in ${UV_BIN})"
done
say "console scripts installed: mem0-mcp-selfhosted, mem0-hook-context, mem0-hook-stop"

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

# --- 4. API keys + embedding/reranking provider ------------------------------
step "4/8  API keys + embedding/reranking provider"

# Read a value out of the existing env file (for idempotent re-runs). Prints
# nothing if the file or key is absent.
env_val() {
  [ -f "$ENV_FILE" ] || return 0
  grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true
}

# 4a. OpenAI key — Mem0's LLM extracts facts on every provider, so this is
# always required (reused for the embedder too when the provider is openai).
EXISTING_KEY="$(env_val OPENAI_API_KEY)"
if [ -n "$EXISTING_KEY" ] && [ "$EXISTING_KEY" != "__OPENAI_API_KEY__" ]; then
  say "reusing existing OpenAI key from ${ENV_FILE}"
  OPENAI_KEY="$EXISTING_KEY"
else
  printf "  Enter your OpenAI API key (LLM fact extraction; input hidden): "
  read -rs OPENAI_KEY
  printf "\n"
  [ -n "$OPENAI_KEY" ] || die "no key entered"
  case "$OPENAI_KEY" in
    sk-*) say "key captured" ;;
    *) die "that doesn't look like an OpenAI key (expected to start with 'sk-')" ;;
  esac
fi

# 4b. Embedding + reranking provider. Reuse the prior choice on re-runs;
# otherwise prompt (default: openai).
EXISTING_PROVIDER="$(env_val MEM0_EMBED_PROVIDER)"
case "$EXISTING_PROVIDER" in
  openai|zeroentropy)
    PROVIDER="$EXISTING_PROVIDER"
    say "reusing embedding/reranking provider from ${ENV_FILE}: ${PROVIDER}"
    ;;
  *)
    printf "  Embedding + reranking provider? [openai/zeroentropy] (default openai): "
    read -r PROVIDER || true
    PROVIDER="$(printf '%s' "${PROVIDER:-openai}" | tr '[:upper:]' '[:lower:]')"
    ;;
esac

ZE_KEY=""
case "$PROVIDER" in
  openai)
    EMBED_PROVIDER="openai"
    EMBED_MODEL="text-embedding-3-small"
    EMBED_DIMS="1536"
    RERANK_PROVIDER=""
    RERANK_MODEL=""
    say "embeddings: OpenAI text-embedding-3-small (1536d); reranking: off"
    ;;
  zeroentropy)
    EMBED_PROVIDER="zeroentropy"
    EMBED_MODEL="zembed-1"
    EMBED_DIMS="2560"
    RERANK_PROVIDER="zero_entropy"
    RERANK_MODEL="zerank-1"
    EXISTING_ZE="$(env_val ZEROENTROPY_API_KEY)"
    if [ -n "$EXISTING_ZE" ] && [ "$EXISTING_ZE" != "__ZEROENTROPY_API_KEY__" ]; then
      say "reusing existing ZeroEntropy key from ${ENV_FILE}"
      ZE_KEY="$EXISTING_ZE"
    else
      printf "  Enter your ZeroEntropy API key (input hidden): "
      read -rs ZE_KEY
      printf "\n"
      [ -n "$ZE_KEY" ] || die "no ZeroEntropy key entered"
      say "ZeroEntropy key captured"
    fi
    say "embeddings: ZeroEntropy zembed-1 (2560d); reranking: zerank-1"
    ;;
  *)
    die "unknown provider '${PROVIDER}' (expected: openai or zeroentropy)"
    ;;
esac

# --- 5. Create dirs + render config -----------------------------------------
step "5/8  Config + data dirs"
mkdir -p "$CONFIG_DIR" "$QDRANT_STORAGE" "$LA_DIR"
KEY="$OPENAI_KEY" ZE_KEY="$ZE_KEY" \
  EMBED_PROVIDER="$EMBED_PROVIDER" EMBED_MODEL="$EMBED_MODEL" EMBED_DIMS="$EMBED_DIMS" \
  RERANK_PROVIDER="$RERANK_PROVIDER" RERANK_MODEL="$RERANK_MODEL" \
  awk '{
    gsub(/__OPENAI_API_KEY__/, ENVIRON["KEY"]);
    gsub(/__ZEROENTROPY_API_KEY__/, ENVIRON["ZE_KEY"]);
    gsub(/__EMBED_PROVIDER__/, ENVIRON["EMBED_PROVIDER"]);
    gsub(/__EMBED_MODEL__/, ENVIRON["EMBED_MODEL"]);
    gsub(/__EMBED_DIMS__/, ENVIRON["EMBED_DIMS"]);
    gsub(/__RERANK_PROVIDER__/, ENVIRON["RERANK_PROVIDER"]);
    gsub(/__RERANK_MODEL__/, ENVIRON["RERANK_MODEL"]);
    print
  }' "${TEMPLATES}/env.template" > "$ENV_FILE"
chmod 600 "$ENV_FILE"
say "wrote ${ENV_FILE} (chmod 600, provider: ${PROVIDER})"
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
printf "  • Embeddings:    %s (%s, %sd)\n" "$EMBED_PROVIDER" "$EMBED_MODEL" "$EMBED_DIMS"
printf "  • Reranking:     %s\n" "${RERANK_MODEL:-off}"
printf "  • Qdrant:        %s (native, no Docker)\n" "$QDRANT_URL"
printf "  • Memory store:  %s (local, per-machine)\n" "$QDRANT_STORAGE"
printf "  • Logs:          %s/{qdrant,server}.log\n" "$DATA_DIR"
printf "\n${BOLD}Restart your Claude Code session${NC} so the MCP server (.mcp.json) and\n"
printf "the SessionStart/Stop hooks attach. Then run ${BLUE}/mem0-brady:doctor${NC} to verify.\n"
