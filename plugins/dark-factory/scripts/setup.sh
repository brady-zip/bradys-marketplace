#!/usr/bin/env bash
#
# setup.sh - coordinated, idempotent, project-scoped setup for the dark factory
# radio pattern. Deploys the radio assets into the CURRENT git repo for BOTH runtimes
# (Claude Code cannot install a plugin into Codex, so Codex needs the committed
# copies), provisions GSD (get-shit-done core) for Codex, wires the identity env +
# SessionEnd cleanup into .claude/settings.json, merges the Codex SessionStart
# prelude adapter into .codex/hooks.json, and runs `h5i init`.
#
# Modes:
#   (default)    apply: create/update managed files, provision GSD, merge settings/hooks, run h5i init
#   --check      read-only; report status; exit 3 if anything is pending
#   --dry-run    show what would change; write nothing
#   --force      overwrite a managed file the user has locally edited
#   --skip-h5i-init   do not run `h5i init`
#   --skip-gsd        do not provision GSD (get-shit-done core)
#
# Everything is driven by deploy-manifest.json next to this script's parent.
# The engine never rewrites unrelated settings.json / .codex/hooks.json keys,
# backs each target up before any write, and writes atomically. Per-file status is
# computed from the actual write outcome (not intent): a copy that does not land
# (e.g. a sandbox-blocked path) is reported FAILED and gives a non-zero exit. GSD
# is installed via `npx` from its pinned npm package, forced LOCAL (into <repo>/.codex,
# never a global ~/.codex), non-interactively (GSD_INSTALLER_MIGRATION_RESOLVE=keep so
# its baseline scan does not block on dark-factory's own GSD-shaped assets), and is
# skipped when already present.

set -u

MODE="apply"
FORCE="no"
RUN_H5I_INIT="yes"
RUN_GSD="yes"
for a in "$@"; do
  case "$a" in
    --check)        MODE="check" ;;
    --dry-run)      MODE="dry-run" ;;
    --force)        FORCE="yes" ;;
    --skip-h5i-init) RUN_H5I_INIT="no" ;;
    --skip-gsd)      RUN_GSD="no" ;;
    -h|--help)
      sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'setup: unknown arg: %s\n' "$a" >&2; exit 2 ;;
  esac
done

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
say()  { printf '%b\n' "$1"; }
info() { printf '  %b\n' "$1"; }

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$PLUGIN_ROOT/deploy-manifest.json"
[ -f "$MANIFEST" ] || { say "${RED}manifest not found: $MANIFEST${NC}"; exit 1; }

# --- preflight ---------------------------------------------------------------
say "${BOLD}Preflight${NC}"
if ! bash "$PLUGIN_ROOT/scripts/check-setup.sh"; then
  say "\n${RED}Preflight failed - fix the items above and re-run.${NC}"
  exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { say "${RED}not inside a git repository${NC}"; exit 1; }
SETTINGS_REL="$(jq -r '.settingsPath' "$MANIFEST")"
SETTINGS="$REPO_ROOT/$SETTINGS_REL"

PENDING=0
CREATED=0; UPDATED=0; UNCHANGED=0; CONFLICT=0; SKIPPED=0; FAILED=0

apply_enabled() { [ "$MODE" = "apply" ]; }

# --- files -------------------------------------------------------------------
say "\n${BOLD}Files${NC} (repo: $REPO_ROOT)"
while IFS= read -r obj; do
  src_rel="$(printf '%s' "$obj" | jq -r '.source')"
  dest_rel="$(printf '%s' "$obj" | jq -r '.dest')"
  executable="$(printf '%s' "$obj" | jq -r '.executable // false')"
  noclobber="$(printf '%s' "$obj" | jq -r '.noClobber // false')"
  src="$PLUGIN_ROOT/$src_rel"
  dest="$REPO_ROOT/$dest_rel"

  if [ ! -f "$src" ]; then
    say "  ${RED}ERROR${NC}   missing plugin source: $src_rel"; CONFLICT=$((CONFLICT+1)); PENDING=$((PENDING+1)); continue
  fi

  if [ ! -f "$dest" ]; then
    action="create"
  elif cmp -s "$src" "$dest"; then
    action="unchanged"
  elif [ "$noclobber" = "true" ]; then
    action="skip-noclobber"
  elif [ "$FORCE" = "yes" ]; then
    action="update"
  else
    action="conflict"
  fi

  case "$action" in
    unchanged) info "${GREEN}unchanged${NC} $dest_rel"; UNCHANGED=$((UNCHANGED+1)) ;;
    create|update)
      PENDING=$((PENDING+1))
      if apply_enabled; then
        # Status is computed from OUTCOME, not intent. mkdir/cp can fail silently
        # (e.g. an agent Bash sandbox / macOS seatbelt blocks .claude/commands/ even
        # though a sibling like .claude/skills/ writes fine). Capture their stderr,
        # check the exit status, and confirm the destination now matches the source
        # byte-for-byte before counting it created/updated — otherwise mark FAILED so
        # the summary and exit code reflect reality instead of claiming success.
        werr="$( { mkdir -p "$(dirname "$dest")" && cp "$src" "$dest"; } 2>&1 )"
        if [ $? -eq 0 ] && cmp -s "$src" "$dest"; then
          [ "$executable" = "true" ] && chmod +x "$dest"
          if [ "$action" = "create" ]; then CREATED=$((CREATED+1)); else UPDATED=$((UPDATED+1)); fi
          info "${GREEN}${action}d${NC} $dest_rel"
        else
          FAILED=$((FAILED+1))
          info "${RED}FAILED${NC}   $dest_rel (write did not land)"
          [ -n "$werr" ] && info "         ${RED}${werr}${NC}"
          info "         source: ${src#$PLUGIN_ROOT/}"
          info "         this path may be blocked by an agent's Bash sandbox (macOS seatbelt);"
          info "         place the file by hand (editor / Claude Code Write tool), or re-run in a plain terminal."
        fi
      else
        if [ "$action" = "create" ]; then CREATED=$((CREATED+1)); else UPDATED=$((UPDATED+1)); fi
        info "${YELLOW}would-${action}${NC} $dest_rel"
      fi ;;
    skip-noclobber)
      SKIPPED=$((SKIPPED+1))
      info "${YELLOW}exists (not overwritten)${NC} $dest_rel"
      info "        differs from plugin copy; review and merge by hand if needed (noClobber)." ;;
    conflict)
      CONFLICT=$((CONFLICT+1)); PENDING=$((PENDING+1))
      info "${RED}CONFLICT${NC} $dest_rel (locally edited; pass --force to overwrite)" ;;
  esac
done < <(jq -c '.objects[] | select(.type=="file")' "$MANIFEST")

# --- GSD (get-shit-done core) ------------------------------------------------
# Provision GSD for Codex via its own npm installer (pinned). Idempotent: skip
# when already present. GSD owns .codex/hooks.json, so this must run BEFORE the
# Codex-hooks merge below, which appends our SessionStart adapter into it.
say "\n${BOLD}GSD (get-shit-done core)${NC}"
GSD_PKG="$(jq -r '.gsd.package // empty' "$MANIFEST")"
GSD_VER="$(jq -r '.gsd.version // empty' "$MANIFEST")"
GSD_RUNTIME="$(jq -r '.gsd.runtime // "codex"' "$MANIFEST")"
GSD_LOCATION="$(jq -r '.gsd.location // "local"' "$MANIFEST")"
GSD_PROFILE="$(jq -r '.gsd.scope // "full"' "$MANIFEST")"
GSD_MIGRATION_RESOLVE="$(jq -r '.gsd.migrationResolve // "keep"' "$MANIFEST")"
GSD_MARKER="$(jq -r '.gsd.presenceMarker // ".codex/gsd-core"' "$MANIFEST")"
GSD_SPEC="${GSD_PKG}@${GSD_VER}"
# Install into the PROJECT, not globally. Left to its own devices under a
# non-interactive terminal (which is exactly how it runs from inside an agent),
# GSD's installer defaults to a *global* install into ~/.codex - which never
# creates the repo-local marker (so --check would report GSD pending forever) and,
# on a seatbelt-sandboxed ~/.codex, cannot write at all. `--local` targets
# <repo>/.codex, matching GSD_MARKER (.codex/gsd-core) and staying inside the repo.
# GSD_INSTALLER_MIGRATION_RESOLVE=keep resolves GSD's first-time baseline scan
# non-interactively: it would otherwise hard-block on dark-factory's own
# GSD-shaped assets (e.g. skills/gsd-h5i-code-review/agents/openai.yaml, which
# GSD's classifier flags "stale-gsd-looking" and, in a non-TTY run, throws on
# instead of prompting). `keep` = preserve those files on disk = the correct call.
GSD_ARGS=(--"$GSD_RUNTIME" --"$GSD_LOCATION" --profile="$GSD_PROFILE")
if [ "$RUN_GSD" = "no" ]; then
  info "skipped (--skip-gsd)"
elif [ -z "$GSD_PKG" ] || [ -z "$GSD_VER" ]; then
  info "${YELLOW}no gsd config in manifest${NC} - skipping"
elif [ -e "$REPO_ROOT/$GSD_MARKER" ]; then
  info "${GREEN}already provisioned${NC} ($GSD_MARKER present)"
elif ! command -v npx >/dev/null 2>&1; then
  info "${RED}npx not found${NC} - cannot provision GSD (install Node.js); continuing"
elif [ "$MODE" != "apply" ]; then
  info "${YELLOW}would run${NC} GSD_INSTALLER_MIGRATION_RESOLVE=$GSD_MIGRATION_RESOLVE npx -y --package=$GSD_SPEC -- gsd-core ${GSD_ARGS[*]}"
  PENDING=$((PENDING+1))
else
  info "provisioning locally (into ./$GSD_MARKER) via npx (pulls $GSD_SPEC; may hit the network)..."
  if ( cd "$REPO_ROOT" && GSD_INSTALLER_MIGRATION_RESOLVE="$GSD_MIGRATION_RESOLVE" npx -y --package="$GSD_SPEC" -- gsd-core "${GSD_ARGS[@]}" ); then
    info "${GREEN}provisioned${NC} GSD ${GSD_ARGS[*]}"
  else
    info "${RED}GSD install failed${NC} (continuing; run it manually in a plain terminal if needed)"
  fi
fi

# --- Codex hooks (merge; non-destructive, coexists with GSD) -----------------
# .codex/hooks.json may be owned by GSD (or absent). Append our SessionStart
# adapter entry only if not already present; never rewrite GSD's other entries.
say "\n${BOLD}Codex hooks${NC} (.codex/hooks.json)"
while IFS= read -r frag; do
  src_rel="$(printf '%s' "$frag" | jq -r '.source')"
  dest_rel="$(printf '%s' "$frag" | jq -r '.dest')"
  event="$(printf '%s' "$frag" | jq -r '.event')"
  match="$(printf '%s' "$frag" | jq -r '.matchCommand')"
  src="$PLUGIN_ROOT/$src_rel"
  dest="$REPO_ROOT/$dest_rel"

  if [ ! -f "$src" ]; then
    say "  ${RED}ERROR${NC}   missing plugin source: $src_rel"; CONFLICT=$((CONFLICT+1)); PENDING=$((PENDING+1)); continue
  fi
  entry="$(jq -c --arg ev "$event" '.hooks[$ev][0]' "$src")"
  if [ -z "$entry" ] || [ "$entry" = "null" ]; then
    say "  ${RED}ERROR${NC}   $src_rel has no .hooks.$event entry"; CONFLICT=$((CONFLICT+1)); PENDING=$((PENDING+1)); continue
  fi

  existing='{}'
  if [ -f "$dest" ]; then
    if ! existing="$(jq -e '.' "$dest" 2>/dev/null)"; then
      say "  ${RED}ERROR${NC}   $dest_rel is not valid JSON - fix it and re-run"; CONFLICT=$((CONFLICT+1)); PENDING=$((PENDING+1)); continue
    fi
  fi

  present="$(printf '%s' "$existing" | jq --arg ev "$event" --arg m "$match" \
    '[ (.hooks[$ev] // [])[].hooks[]?.command // empty ] | any(. | contains($m))')"
  if [ "$present" = "true" ]; then
    info "${GREEN}unchanged${NC} $dest_rel (SessionStart adapter already present)"
  else
    PENDING=$((PENDING+1))
    work="$(printf '%s' "$existing" | jq --arg ev "$event" --argjson entry "$entry" \
      '.hooks = (.hooks // {}) | .hooks[$ev] = ((.hooks[$ev] // []) + [$entry])')"
    if apply_enabled; then
      mkdir -p "$(dirname "$dest")"
      if [ -f "$dest" ]; then
        backup="$dest.bak.$(date +%s)"; cp "$dest" "$backup"; info "backup: ${backup#$REPO_ROOT/}"
      fi
      tmp="$dest.tmp.$$"
      if { printf '%s\n' "$work" | jq . > "$tmp"; } 2>/dev/null && mv "$tmp" "$dest" 2>/dev/null; then
        info "${GREEN}merged${NC} SessionStart adapter into $dest_rel"
      else
        rm -f "$tmp" 2>/dev/null
        FAILED=$((FAILED+1))
        info "${RED}FAILED${NC}   $dest_rel (could not write merged hooks - path may be sandbox-blocked)"
      fi
    else
      info "${YELLOW}would-merge${NC} SessionStart adapter into $dest_rel"
    fi
  fi
done < <(jq -c '.objects[] | select(.type=="codex-hook-merge")' "$MANIFEST")

# --- settings.json -----------------------------------------------------------
say "\n${BOLD}settings.json${NC} ($SETTINGS_REL)"
existing='{}'
if [ -f "$SETTINGS" ]; then
  if ! existing="$(jq -e '.' "$SETTINGS" 2>/dev/null)"; then
    say "  ${RED}ERROR${NC}   $SETTINGS_REL is not valid JSON - fix it and re-run"; CONFLICT=$((CONFLICT+1)); existing='{}'
  fi
fi

work="$existing"
while IFS= read -r frag; do
  kind="$(printf '%s' "$frag" | jq -r '.kind')"
  case "$kind" in
    env)
      key="$(printf '%s' "$frag" | jq -r '.key')"
      val="$(printf '%s' "$frag" | jq -r '.value')"
      work="$(printf '%s' "$work" | jq --arg k "$key" --arg v "$val" '.env = (.env // {}) | .env[$k] = $v')"
      ;;
    hook)
      event="$(printf '%s' "$frag" | jq -r '.event')"
      match="$(printf '%s' "$frag" | jq -r '.matchCommand // empty')"
      entry="$(printf '%s' "$frag" | jq -c '.entry')"
      present="$(printf '%s' "$work" | jq --arg ev "$event" --arg m "$match" \
        '[ (.hooks[$ev] // [])[].hooks[]?.command // empty ] | any(. | contains($m))')"
      if [ "$present" != "true" ]; then
        work="$(printf '%s' "$work" | jq --arg ev "$event" --argjson entry "$entry" \
          '.hooks = (.hooks // {}) | .hooks[$ev] = ((.hooks[$ev] // []) + [$entry])')"
      fi
      ;;
  esac
done < <(jq -c '.objects[] | select(.type=="settings-fragment")' "$MANIFEST")

if [ "$(printf '%s' "$existing" | jq -S .)" = "$(printf '%s' "$work" | jq -S .)" ]; then
  info "${GREEN}unchanged${NC} env.H5I_AGENT + SessionEnd hook already present"
else
  PENDING=$((PENDING+1))
  if apply_enabled; then
    mkdir -p "$(dirname "$SETTINGS")"
    if [ -f "$SETTINGS" ]; then
      backup="$SETTINGS.bak.$(date +%s)"
      cp "$SETTINGS" "$backup"
      info "backup: ${backup#$REPO_ROOT/}"
    fi
    tmp="$SETTINGS.tmp.$$"
    if { printf '%s\n' "$work" | jq . > "$tmp"; } 2>/dev/null && mv "$tmp" "$SETTINGS" 2>/dev/null; then
      info "${GREEN}updated${NC} env.H5I_AGENT=claude + SessionEnd release hook"
    else
      rm -f "$tmp" 2>/dev/null
      FAILED=$((FAILED+1))
      info "${RED}FAILED${NC}   $SETTINGS_REL (could not write settings - path may be sandbox-blocked)"
    fi
  else
    info "${YELLOW}would-update${NC} env.H5I_AGENT=claude + SessionEnd release hook"
  fi
fi

# --- h5i init ----------------------------------------------------------------
say "\n${BOLD}h5i init${NC}"
h5i_initialized() { [ -f "$REPO_ROOT/.claude/h5i.md" ] && [ -f "$REPO_ROOT/AGENTS.md" ]; }
if [ "$RUN_H5I_INIT" = "no" ]; then
  info "skipped (--skip-h5i-init)"
elif h5i_initialized; then
  info "${GREEN}already initialized${NC} (.claude/h5i.md + AGENTS.md present)"
elif [ "$MODE" != "apply" ]; then
  info "${YELLOW}would run${NC} h5i init (generates .claude/h5i.md + AGENTS.md)"
  PENDING=$((PENDING+1))
else
  if h5i init; then
    info "${GREEN}ran${NC} h5i init"
  else
    info "${RED}h5i init failed${NC} (continuing; run it manually if needed)"
  fi
fi

# --- summary -----------------------------------------------------------------
say "\n${BOLD}Summary${NC}"
say "  files: ${CREATED} created, ${UPDATED} updated, ${UNCHANGED} unchanged, ${SKIPPED} skipped, ${CONFLICT} conflict, ${FAILED} failed"
if [ "$MODE" = "check" ]; then
  if [ "$PENDING" -gt 0 ]; then say "  ${YELLOW}${PENDING} item(s) pending${NC} - run setup to apply"; exit 3; fi
  say "  ${GREEN}up to date${NC}"; exit 0
fi
if [ "$MODE" = "dry-run" ]; then
  say "  dry run - nothing written (${PENDING} item(s) would change)"; exit 0
fi
if [ "$FAILED" -gt 0 ]; then
  say "  ${RED}${FAILED} file(s) failed to write${NC} - the deploy is INCOMPLETE (see the FAILED line(s) above)."
  say "  A common cause is an agent Bash sandbox blocking a path such as .claude/commands/ (while"
  say "  .claude/skills/ writes fine). Place the failed file(s) by hand, or re-run this setup in a"
  say "  plain, unsandboxed terminal. Not printing 'Next steps' - setup did not complete cleanly."
  exit 1
fi
if [ "$CONFLICT" -gt 0 ]; then
  say "  ${RED}${CONFLICT} conflict(s)${NC} not applied - re-run with --force after reviewing"; exit 1
fi
say "\n${BOLD}Next steps${NC}"
info "1. Launch Codex with its identity:  ${BLUE}H5I_AGENT=codex codex${NC}"
info "2. In Codex, trust project hooks via /hooks so the SessionStart prelude runs."
info "3. ${BOLD}Commit${NC} the deployed files - GSD-style resets discard uncommitted work,"
info "   and Codex reads the committed .codex/ copies:"
info "     git add .claude .codex .dark-factory AGENTS.md && git commit -m 'chore: dark factory radio setup'"
info "4. Enter radio: ${BLUE}/radio${NC} (Claude) or the ${BLUE}radio${NC} prompt (Codex)."
info "   Fresh identity: ${BLUE}/radio claude-roadmap${NC}. One live session per identity."
exit 0
