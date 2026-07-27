#!/usr/bin/env bash
# lib-mcp.sh — minimal streamable-HTTP MCP client for the plugin's shell scripts.
#
# Sourced, never exec'd. Enough of the protocol to call a tool and read its text
# result: initialize (which returns the session id every later request must
# carry), the initialized notification, then tools/call. Responses come back as
# SSE frames, so the payload is the `data:` line.
#
# Exists so setup.sh and scopes.sh ask the store the same way. They both need to
# know which partitions already hold memories, and two hand-rolled copies of a
# handshake is how they end up disagreeing about the answer.
#
# Fails CLOSED but quietly: every function returns non-zero on any problem and
# prints nothing, so a caller can treat the store inventory as optional without
# writing error handling around each call.

MEM0_MCP_SESSION=""

# Extra request headers, read from the same MEM0_MCP_HEADERS the Python client
# reads (mcp_client.py). One variable on purpose: two names for one credential
# is how one of them ends up unset, and the symptom — doctor reporting a store
# it cannot reach while the hooks reach it fine, or the reverse — reads as a
# server problem rather than a config one.
#
# Held as an array of ready-made curl arguments so a header value containing
# spaces survives; expanded with the ${a[@]+"${a[@]}"} idiom because an empty
# array under `set -u` is an unbound-variable error in bash before 4.4, and
# macOS still ships 3.2.
MEM0_MCP_HEADER_ARGS=()

_mcp_load_header_args() {
  MEM0_MCP_HEADER_ARGS=()
  [ -n "${MEM0_MCP_HEADERS:-}" ] || return 0
  local line
  while IFS= read -r line; do
    [ -n "$line" ] && MEM0_MCP_HEADER_ARGS+=("$line")
  done < <(printf '%s' "$MEM0_MCP_HEADERS" |
    jq -r 'to_entries[] | "-H", "\(.key): \(.value)"' 2>/dev/null)
}

# mcp_init <url>
# Handshake and stash the session id. Returns non-zero if the server is
# unreachable, is not an MCP endpoint, or curl/jq are missing.
mcp_init() {
  local url="${1:-}"
  [ -n "$url" ] || return 1
  command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 1
  MEM0_MCP_URL_RESOLVED="$url"
  _mcp_load_header_args
  MEM0_MCP_SESSION="$(curl -s -D- -o /dev/null --max-time 5 -X POST "$url" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    ${MEM0_MCP_HEADER_ARGS[@]+"${MEM0_MCP_HEADER_ARGS[@]}"} \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"mem0-brady","version":"1"}}}' \
    2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}')"
  [ -n "$MEM0_MCP_SESSION" ] || return 1
  curl -s --max-time 5 -X POST "$url" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "mcp-session-id: $MEM0_MCP_SESSION" \
    ${MEM0_MCP_HEADER_ARGS[@]+"${MEM0_MCP_HEADER_ARGS[@]}"} \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null 2>&1
  return 0
}

# mcp_call <tool> <json-args>
# Echo the tool's text payload. Requires a prior successful mcp_init.
mcp_call() {
  [ -n "$MEM0_MCP_SESSION" ] || return 1
  local out
  out="$(curl -s --max-time 15 -X POST "$MEM0_MCP_URL_RESOLVED" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "mcp-session-id: $MEM0_MCP_SESSION" \
    ${MEM0_MCP_HEADER_ARGS[@]+"${MEM0_MCP_HEADER_ARGS[@]}"} \
    -d "$(jq -nc --arg n "$1" --argjson a "${2:-\{\}}" \
        '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:$n,arguments:$a}}')" \
    2>/dev/null | sed -n 's/^data: //p' | jq -r '.result.content[0].text // empty' 2>/dev/null)"
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# mcp_app_id_counts
# Echo "<count> <app_id>" lines for every app_id currently holding memories.
#
# app_id lives in each memory's metadata rather than as a top-level entity, so
# list_entities (users/agents/runs) cannot report it — the inventory has to come
# from paging memories and counting. Memories with no app_id are reported as
# "(none)" so a partition-less write is visible rather than silently absent.
mcp_app_id_counts() {
  mcp_call get_memories '{"limit":2000}' \
    | jq -r 'if type=="object" then (.results // .memories // []) else . end
             | map(.metadata.app_id // "(none)") | group_by(.)
             | map("\(length) \(.[0])") | .[]' 2>/dev/null \
    | sort -rn
}
