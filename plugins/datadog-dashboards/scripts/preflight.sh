#!/usr/bin/env bash
#
# Preflight + self-repair for the datadog-dashboards plugin.
#
# WHY THIS EXISTS
# ---------------
# check-setup.sh is a *diagnostic* the user runs when something already broke.
# This script is the *gate* every skill runs before it does any work, on every
# invocation.
#
# It exists because the old diagnostic gave a confident wrong answer. Its probe
# was:
#
#     uvx llm models 2>/dev/null | grep -i gemini
#
# On a machine with `llm` + `llm-gemini` + a valid key installed since May, that
# printed nothing, and a create -> expand -> iterate run concluded Gemini was
# unavailable. `uvx llm` runs an EPHEMERAL environment containing only `llm` and
# no plugins -- unless uv happens to find a persistent `llm` tool to reuse, which
# depends on *which* uv is first on PATH. On the box in question uv resolved
# inside a mise-managed python (.../mise/installs/python/3.12.10/bin/uv) with its
# own tool directory, so there was no persistent tool to reuse and `gemini/*`
# models simply did not exist in the env being probed. Nothing was broken except
# the question being asked.
#
# Hence the detection below: ask the `llm` on PATH first, and treat `uvx llm`
# only as a fallback. A check that can be confidently wrong is worse than no
# check, because it sends everyone hunting the wrong thing.
#
# So this script is built around three rules:
#
#   1. IT RUNS EVERY TIME. No cache, no stamp file, no "already checked this
#      session". The plugin is published to people who don't know its internals,
#      on machines that drift: a `brew uninstall`, a wiped `uv tool` dir, an
#      expired Datadog key, a Chrome Beta that isn't running today, a different
#      uv winning a PATH race. State from five minutes ago is not evidence about
#      now. Every check is therefore cheap enough to pay for on each run (see
#      TIMEOUT below).
#
#      Note what this rule does NOT buy you. Preflight is about the machine. It
#      cannot make a skill hand off to the next skill, and the run that prompted
#      all of this was never environment-blocked -- it dropped one handoff line
#      and silently deleted two downstream skills. A green preflight is not
#      evidence that a run was complete; that is what the completion ledgers in
#      each SKILL.md are for. Do not let one stand in for the other.
#
#   2. IT REPAIRS WHAT IT CAN. A check that only prints "MISSING: llm-gemini"
#      pushes the work back onto a user who has no idea what that is. Anything
#      installable without a human decision (uv, the llm tool, the llm-gemini
#      plugin, mise, node@22, jq) is installed here, automatically. Repairs are
#      idempotent and re-runnable, so a healthy machine no-ops.
#
#   3. WHAT IT CANNOT REPAIR, IT SURFACES LOUDLY. Secrets (DD_API_KEY,
#      DD_APP_KEY, the Gemini key), GUI apps (Chrome Beta), a running browser
#      session, and the internal `chart-room` binary all need a human. Those
#      exit non-zero with the exact command to run. The calling skill is required
#      to stop and show the user this output verbatim -- the original failure was
#      not that a dependency was missing, it was that the user was never told.
#
# EXIT CODES
#   0  OK or REPAIRED  -- safe to proceed
#   1  BLOCKED         -- a dependency the requested skill needs is missing and
#                         needs a human. The caller MUST stop and show the user.
#
# The last lines of stdout are a machine-readable block (PREFLIGHT_STATUS: ...)
# so a skill can branch on the result without re-parsing the human report.
#
# USAGE
#   preflight.sh [--skill create|expand|iterate|all] [--no-repair] [--smoke] [--brief]
#
#   --brief    Print a few summary lines instead of the full per-check report, and
#              tee the full report to a log file. Intended for the automatic
#              invocation at the top of each skill, where a healthy machine should
#              cost three lines of context rather than forty. On anything other
#              than a clean pass the summary still carries the complete USER
#              ACTION REQUIRED / repaired / deferred blocks -- the detail that gets
#              elided is the list of things that went fine. "A clean pass" means
#              no blockers AND no deferrals: a deferral is what the NEXT skill in
#              the chain walks into, and the contract requires the caller to warn
#              about it now, which it cannot do if this mode threw it away. The
#              log path is printed (as PREFLIGHT_LOG:) whenever anything at all
#              was reported, so the full output is one `cat` away when a check
#              misbehaves.
#
#   --skill    Which skill is about to run. Decides which failures BLOCK now and
#              which are merely DEFERRED warnings. `create` doesn't need Chrome
#              Beta yet, but it will by the time the chain reaches iterate, so
#              the dependency is still reported -- just not fatal. Default: all.
#   --no-repair  Diagnose only; never install anything. For CI and for users who
#              want to see what would change first.
#   --smoke    Also make one real (tiny) Gemini API call. This is the only check
#              that proves the model is actually reachable -- `llm models` listing
#              a gemini model says nothing about whether the key is valid, or
#              whether a corporate SOCKS proxy will strangle the request.
#              Implied by --skill iterate, because that skill's entire loop is
#              Gemini calls and discovering a dead key on iteration 1 wastes a
#              screenshot round-trip.

set -u

# Never let a hung network call turn the gate into the outage. Every external
# command below is wrapped in run_with_timeout.
TIMEOUT="${DD_DASH_PREFLIGHT_TIMEOUT:-90}"

SKILL="all"
REPAIR=1
SMOKE=0
BRIEF=0

while [ $# -gt 0 ]; do
  case "$1" in
    --skill) SKILL="${2:-all}"; shift 2 ;;
    --skill=*) SKILL="${1#*=}"; shift ;;
    --no-repair) REPAIR=0; shift ;;
    --smoke) SMOKE=1; shift ;;
    --brief) BRIEF=1; shift ;;
    -h|--help) sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'preflight: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

case "$SKILL" in
  create|expand|iterate|all) : ;;
  *) printf 'preflight: --skill must be one of create|expand|iterate|all (got %s)\n' "$SKILL" >&2; exit 2 ;;
esac

# iterate IS the Gemini loop, so proving the model answers is not optional there.
# `all` implies it too: a scope named "all" that runs fewer checks than `iterate`
# is a trap, and the 15-vs-16 discrepancy read like a bug to the first person who
# compared them. Costs one tiny billable Gemini call -- see the note on
# check-setup.sh about not putting this in a cron loop.
case "$SKILL" in iterate|all) SMOKE=1 ;; esac

# Honour the user's global opt-out, but say so rather than silently degrading.
if [ "${DD_DASH_PREFLIGHT_AUTOFIX:-1}" = "0" ]; then
  REPAIR=0
fi

if [ "$BRIEF" = 1 ] && [ -z "${DD_DASH_PREFLIGHT_INNER:-}" ]; then
  LOG="${TMPDIR:-/tmp}"; LOG="${LOG%/}/dd-dash-preflight-$(date +%Y%m%d-%H%M%S)-$$.log"

  # Re-exec ourselves without --brief and capture the whole report. Doing it as a
  # re-exec, rather than threading a quiet flag through thirty call sites, keeps
  # one code path producing the report; --brief only decides how much of it
  # reaches stdout.
  INNER_ARGS="--skill $SKILL"
  [ "$REPAIR" = 0 ] && INNER_ARGS="$INNER_ARGS --no-repair"
  [ "$SMOKE" = 1 ] && INNER_ARGS="$INNER_ARGS --smoke"
  DD_DASH_PREFLIGHT_INNER=1 DD_DASH_PREFLIGHT_COLOR="" \
    bash "$0" $INNER_ARGS >"$LOG" 2>&1
  INNER_RC=$?

  # Read the machine-readable tail out of the log before deciding what to keep.
  TAIL_BLOCK="$(grep '^PREFLIGHT_' "$LOG" 2>/dev/null)"
  STATUS="$(printf '%s\n' "$TAIL_BLOCK" | sed -n 's/^PREFLIGHT_STATUS: //p' | tail -1)"
  N_DEFER="$(printf '%s\n' "$TAIL_BLOCK" | sed -n 's/^PREFLIGHT_DEFERRED: //p' | tail -1)"
  # `grep -c` PRINTS 0 and EXITS 1 when there are no matches, so `|| echo 0`
  # appends a second line and the count comes out as "0\n0". Swallow the exit
  # status instead of branching on it.
  N_PASSED="$(grep -c '^  OK ' "$LOG" 2>/dev/null)" || true
  [ -n "$N_PASSED" ] || N_PASSED=0

  printf 'datadog-dashboards preflight (skill=%s): %s -- %s checks passed\n' \
    "$SKILL" "${STATUS:-UNKNOWN}" "$N_PASSED"

  # STATUS is OK when nothing BLOCKS *this* skill -- which says nothing about
  # deferrals, and deferrals are precisely what the next skill in the chain walks
  # into. Eliding them on an OK run (and deleting the log that held them) meant
  # the contract's "if PREFLIGHT_DEFERRED > 0, warn the user now" was unfollowable
  # in the only mode the skills actually invoke. So a deferral keeps the detail
  # and keeps the log, even though the status stays OK.
  if [ "${STATUS:-UNKNOWN}" = "OK" ] && [ "${N_DEFER:-0}" = "0" ] \
     && [ "${DD_DASH_PREFLIGHT_KEEP_LOG:-0}" != "1" ]; then
    # Nothing to investigate, so leave no file behind to go stale. Set
    # DD_DASH_PREFLIGHT_KEEP_LOG=1 to retain it anyway -- CI wants an artifact
    # proving the green run happened, and a deleted log cannot be attached to a
    # build.
    rm -f "$LOG"
  else
    # Everything that is NOT "a check passed" is reproduced in full. A summary
    # that hid the reason a run is about to stop would recreate the exact
    # failure this script was written for. Only the list of things that went
    # fine is elided.
    sed -n '/^Repaired automatically:/,/^$/p'        "$LOG"
    sed -n '/^Not needed yet, but will be:/,/^$/p'   "$LOG"
    sed -n '/^USER ACTION REQUIRED/,/^$/p'           "$LOG"
    printf 'Full report: %s\n' "$LOG"
  fi

  printf '\n%s\n' "$TAIL_BLOCK"
  # Announce the log whenever one still exists -- either because something went
  # wrong, or because KEEP_LOG asked for an artifact of a green run. A retained
  # log nobody is told about is not an artifact.
  [ -f "$LOG" ] && printf 'PREFLIGHT_LOG: %s\n' "$LOG"
  exit "$INNER_RC"
fi

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
if [ ! -t 1 ] && [ -z "${DD_DASH_PREFLIGHT_COLOR:-}" ]; then
  GREEN=''; RED=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi

N_OK=0
N_REPAIRED=0
N_BLOCKED=0
N_DEFERRED=0
BLOCKERS=""
DEFERRALS=""
REPAIRS=""

print_header() { printf "\n${BOLD}%s${NC}\n" "$1"; printf '%s\n' "------------------------------------------------------------"; }
ok()       { printf "  ${GREEN}OK${NC}       %s\n" "$1"; N_OK=$((N_OK + 1)); }
repaired() {
  printf "  ${GREEN}REPAIRED${NC} %s\n" "$1"
  N_REPAIRED=$((N_REPAIRED + 1))
  REPAIRS="${REPAIRS}  - ${1}\n"
}
note()     { printf "           %s\n" "$1"; }
fixhint()  { printf "           ${BLUE}Fix:${NC} %s\n" "$1"; }

# A blocker stops the skill that is about to run. A deferral is a real problem
# that this particular skill can proceed without -- it is still printed, and
# still handed to the user, because the create -> expand -> iterate chain will
# walk into it a few phases later.
blocked() {
  printf "  ${RED}BLOCKED${NC}  %s\n" "$1"
  [ -n "${2:-}" ] && fixhint "$2"
  N_BLOCKED=$((N_BLOCKED + 1))
  BLOCKERS="${BLOCKERS}  - ${1}\n      Fix: ${2:-see above}\n"
}
deferred() {
  printf "  ${YELLOW}DEFERRED${NC} %s\n" "$1"
  [ -n "${2:-}" ] && fixhint "$2"
  N_DEFERRED=$((N_DEFERRED + 1))
  DEFERRALS="${DEFERRALS}  - ${1}\n      Fix: ${2:-see above}\n"
}

# Report a failure as BLOCKED or DEFERRED depending on whether the skill that is
# about to run actually needs it. $1 = comma-separated skills that need it.
needed_by() {
  local needers="$1" msg="$2" fix="${3:-}"
  if [ "$SKILL" = "all" ] || printf '%s' ",$needers," | grep -q ",$SKILL,"; then
    blocked "$msg" "$fix"
  else
    deferred "$msg (needed by: $needers)" "$fix"
  fi
}

# macOS has no coreutils `timeout`, and this plugin is macOS-first. Do it in
# shell so the script has no dependency it is itself responsible for checking.
run_with_timeout() {
  local secs="$1"; shift
  "$@" &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$secs" ]; then
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
}

have() { command -v "$1" >/dev/null 2>&1; }

printf "${BOLD}datadog-dashboards preflight${NC}  (skill=%s, repair=%s, smoke=%s)\n" \
  "$SKILL" "$([ "$REPAIR" = 1 ] && echo on || echo off)" "$([ "$SMOKE" = 1 ] && echo on || echo off)"

# --- uv / uvx -----------------------------------------------------------------
# Everything Python-flavoured in this plugin routes through uv. Repair it first,
# because the llm checks below are meaningless without it.
print_header "uv / uvx"
if have uv && have uvx; then
  ok "uv $(uv --version 2>/dev/null | awk '{print $2}') at $(command -v uv)"
else
  if [ "$REPAIR" = 1 ]; then
    note "installing uv (astral installer -> ~/.local/bin)..."
    if run_with_timeout "$TIMEOUT" sh -c 'curl -LsSf https://astral.sh/uv/install.sh | sh' >/dev/null 2>&1; then
      # The installer writes to ~/.local/bin but cannot edit the PATH of a shell
      # that is already running -- prepend it so the rest of this run sees it.
      PATH="$HOME/.local/bin:$PATH"; export PATH
      if have uv && have uvx; then
        repaired "installed uv to ~/.local/bin"
      else
        needed_by "create,expand,iterate" "uv installed but not on PATH" \
          "Add ~/.local/bin to PATH in your shell profile, then restart your shell."
      fi
    else
      needed_by "create,expand,iterate" "uv not installed and auto-install failed" \
        "curl -LsSf https://astral.sh/uv/install.sh | sh"
    fi
  else
    needed_by "create,expand,iterate" "uv/uvx not on PATH" \
      "curl -LsSf https://astral.sh/uv/install.sh | sh"
  fi
fi

# --- llm + llm-gemini ---------------------------------------------------------
# THE ORIGINAL FAILURE. `uvx llm` reuses an already-installed `llm` uv tool if
# there is one, and falls back to a bare ephemeral env if there isn't -- and a
# bare env has no plugins, so `gemini/...` models simply do not exist. That makes
# "does uvx llm see gemini?" a question about whether `llm` was ever installed as
# a persistent tool WITH the plugin. Install it that way and the ambiguity goes
# away. httpx[socks] is bundled in the same install because corporate SOCKS
# proxies otherwise kill every call with a socksio ImportError that reads like a
# model problem.
print_header "llm + llm-gemini (dashboard evaluation)"
LLM_BIN=""
if have uv; then
  # A `uv tool install --force` that was interrupted leaves the venv working but
  # its receipt (uv-receipt.toml) absent, and from then on every uv invocation
  # prints
  #
  #     warning: Ignoring malformed tool `llm` (run `uv tool uninstall llm` to remove)
  #
  # while `uv tool list` omits llm entirely. The venv itself is fine -- `llm` on
  # PATH works, the gemini plugin is there, live calls succeed -- so the only
  # real consequence is that uv's own bookkeeping (list, upgrade) can't see it.
  #
  # DELIBERATELY NOT AUTO-REPAIRED, despite rule 2. The fix is uninstall +
  # reinstall, and `uv tool install llm --force --with llm-gemini` rebuilds the
  # venv with *only* what that command names -- silently discarding any other
  # llm plugin the user installed themselves. Trading someone's llm-claude or
  # llm-ollama for a cosmetic warning on a working install is not a repair this
  # script gets to make unasked. Surface it, name the cost, let them decide.
  if run_with_timeout 30 sh -c "uv tool list 2>&1 | grep -q 'malformed tool .llm'"; then
    deferred "uv reports a malformed 'llm' tool entry (the install itself works)" \
      "Cosmetic: uv's bookkeeping lost track of llm, but the venv is intact and nothing here is blocked by it. To clean it up: uv tool uninstall llm && uv tool install llm --with llm-gemini --with 'httpx[socks]' -- and re-add any OTHER llm plugins you had, because that rebuilds the environment from scratch."
  fi

  if have llm && run_with_timeout 30 llm --version >/dev/null 2>&1; then
    LLM_BIN="llm"
  elif have uvx && run_with_timeout "$TIMEOUT" uvx llm --version >/dev/null 2>&1; then
    LLM_BIN="uvx llm"
  fi

  gemini_available() {
    [ -n "$LLM_BIN" ] || return 1
    run_with_timeout "$TIMEOUT" sh -c "$LLM_BIN models 2>/dev/null | grep -qi '^GeminiPro:\|gemini/'"
  }

  if gemini_available; then
    ok "llm sees gemini models (via: ${LLM_BIN})"
  elif [ "$REPAIR" = 1 ]; then
    note "no gemini models -- installing llm as a persistent uv tool with the gemini plugin..."
    # --force so a previously-installed plugin-less `llm` gets rebuilt with the
    # extras rather than being reported as "already installed" and left broken.
    if run_with_timeout "$TIMEOUT" uv tool install llm --force --with llm-gemini --with 'httpx[socks]' >/dev/null 2>&1; then
      PATH="$HOME/.local/bin:$PATH"; export PATH
      LLM_BIN="llm"
      have llm || LLM_BIN="uvx llm"
      if gemini_available; then
        repaired "installed llm + llm-gemini + httpx[socks] as a uv tool"
      else
        needed_by "iterate" "llm installed but still reports no gemini models" \
          "uv tool install llm --force --with llm-gemini --with 'httpx[socks]'"
      fi
    else
      needed_by "iterate" "could not install llm + llm-gemini" \
        "uv tool install llm --force --with llm-gemini --with 'httpx[socks]'"
    fi
  else
    needed_by "iterate" "llm has no gemini models configured" \
      "uv tool install llm --force --with llm-gemini --with 'httpx[socks]'"
  fi

  # The specific model the iterate skill asks for by name. A machine can have
  # llm-gemini and still not have this alias after a plugin downgrade, in which
  # case the skill should fall back rather than hard-fail -- so this is never a
  # blocker, only a documented downgrade.
  if [ -n "$LLM_BIN" ]; then
    if run_with_timeout "$TIMEOUT" sh -c "$LLM_BIN models 2>/dev/null | grep -q 'gemini/gemini-2.5-flash'"; then
      ok "preferred model gemini/gemini-2.5-flash available"
    elif run_with_timeout "$TIMEOUT" sh -c "$LLM_BIN models 2>/dev/null | grep -q 'gemini/gemini-3.1-pro-preview'"; then
      deferred "gemini/gemini-2.5-flash missing; iterate must use gemini/gemini-3.1-pro-preview" \
        "uv tool install llm --force --with llm-gemini --with 'httpx[socks]'  (to refresh the model list)"
    fi
  fi

  # An API key. Not repairable -- it is a secret only the user has.
  if [ -n "$LLM_BIN" ]; then
    # Only two things count: a key stored in llm's own keystore, or LLM_GEMINI_KEY.
    # A GEMINI_API_KEY in the environment does NOT satisfy llm-gemini -- it is a
    # Google SDK convention that llm never reads -- and accepting it here produced
    # a green "key present" on a machine where every call failed with
    # "No key found". A check that can be confidently wrong is worse than no check.
    if run_with_timeout 30 sh -c "$LLM_BIN keys 2>/dev/null | grep -q '^gemini$'" \
       || [ -n "${LLM_GEMINI_KEY:-}" ]; then
      ok "Gemini API key present"
    else
      GEMINI_HINT="llm keys set gemini   (paste a key from https://aistudio.google.com/apikey)"
      # Steer the common near-miss rather than letting it look like no key at all.
      [ -n "${GEMINI_API_KEY:-}" ] && GEMINI_HINT="You have GEMINI_API_KEY set, but llm does not read that variable. Run: llm keys set gemini   (or export LLM_GEMINI_KEY=\"\$GEMINI_API_KEY\")"
      needed_by "iterate" "no Gemini API key configured for llm" "$GEMINI_HINT"
    fi
  fi
else
  needed_by "iterate" "skipping llm checks -- uv is unavailable" \
    "Fix the uv failure above first."
fi

# --- SOCKS proxy sanity -------------------------------------------------------
# Only meaningful when the user is actually behind a SOCKS proxy. When they are,
# a missing socksio makes every llm call fail with an error that names socksio,
# not the proxy, and sends people hunting the wrong thing.
#
# THE PROBE ITSELF WAS THE BUG, TWICE OVER. It used to be:
#
#     $LLM_BIN python -c 'import socksio'
#
# `llm python` is not a subcommand (llm 0.35 falls through to `llm prompt` and
# dies with "Got unexpected extra argument"), so the probe failed identically
# whether socksio was installed or not -- permanently BLOCKING `--skill iterate`
# for every user behind a SOCKS proxy, on machines where the real Gemini call
# went through the proxy fine. That is Failure A from the contract doc with a new
# costume on: the machine was healthy and the question was wrong.
#
# So ask the interpreter that actually runs llm. The `llm` shim is a venv console
# script whose shebang names that interpreter; importing there is the same import
# the real call performs. And when we cannot resolve one -- `uvx llm` has no
# stable shim, and an ephemeral env is a different environment anyway -- we say
# UNKNOWN rather than guessing. An unanswerable question is not a failed
# dependency, and the Gemini smoke call below is strictly better evidence.
llm_venv_python() {
  local shim py
  shim="$(command -v llm 2>/dev/null)" || return 1
  [ -n "$shim" ] && [ -f "$shim" ] || return 1
  py="$(sed -n '1s|^#!\([^ ]*\).*|\1|p' "$shim" 2>/dev/null)"
  [ -n "$py" ] && [ -x "$py" ] || return 1
  printf '%s' "$py"
}

# 0 = importable, 1 = definitively missing, 2 = could not ask
socksio_state() {
  local py
  py="$(llm_venv_python)" || return 2
  run_with_timeout 30 "$py" -c 'import socksio' >/dev/null 2>&1 && return 0
  return 1
}

SOCKS_PROXY="${ALL_PROXY:-${all_proxy:-}}"
if [ -n "$SOCKS_PROXY" ] && printf '%s' "$SOCKS_PROXY" | grep -qiE '^socks[0-9a-z]*://'; then
  print_header "SOCKS proxy compatibility"
  socksio_state; SOCKSIO=$?
  if [ "$SOCKSIO" -eq 0 ]; then
    ok "SOCKS proxy in use and socksio is importable by llm"
  elif [ "$SOCKSIO" -eq 2 ]; then
    deferred "SOCKS proxy set; could not determine whether llm has the socks extra" \
      "Not a failure -- there is no resolvable llm venv to ask (usually means llm runs via 'uvx llm'). The live Gemini call below is the real test. To remove the doubt: uv tool install llm --force --with llm-gemini --with 'httpx[socks]'"
  elif [ "$REPAIR" = 1 ] && have uv; then
    if run_with_timeout "$TIMEOUT" uv tool install llm --force --with llm-gemini --with 'httpx[socks]' >/dev/null 2>&1 \
       && { PATH="$HOME/.local/bin:$PATH"; export PATH; socksio_state; [ $? -eq 0 ]; }; then
      repaired "reinstalled llm with httpx[socks] for SOCKS proxy ${SOCKS_PROXY}"
    else
      needed_by "iterate" "SOCKS proxy set but llm lacks the socks extra" \
        "uv tool install llm --force --with llm-gemini --with 'httpx[socks]'"
    fi
  else
    needed_by "iterate" "SOCKS proxy set but llm lacks the socks extra" \
      "uv tool install llm --force --with llm-gemini --with 'httpx[socks]'"
  fi
fi

# --- Live Gemini call ---------------------------------------------------------
# The only check that proves the whole path works: plugin installed, key valid,
# key not expired, network reachable, proxy behaving. Everything above can pass
# while this fails. Run it before the iterate loop rather than discovering it
# after a screenshot round-trip.
if [ "$SMOKE" = 1 ] && [ -n "$LLM_BIN" ] && [ "$N_BLOCKED" -eq 0 ]; then
  print_header "Gemini live call"
  SMOKE_MODEL="gemini/gemini-2.5-flash"
  run_with_timeout "$TIMEOUT" sh -c "$LLM_BIN models 2>/dev/null | grep -q 'gemini/gemini-2.5-flash'" \
    || SMOKE_MODEL="gemini/gemini-3.1-pro-preview"
  SMOKE_OUT="$(run_with_timeout "$TIMEOUT" sh -c "printf 'Reply with the single word: READY' | $LLM_BIN -m $SMOKE_MODEL --no-stream 2>&1")"
  SMOKE_RC=$?
  if [ "$SMOKE_RC" -eq 0 ] && printf '%s' "$SMOKE_OUT" | grep -qi 'READY'; then
    ok "$SMOKE_MODEL answered a live request"
  elif [ "$SMOKE_RC" -eq 124 ]; then
    needed_by "iterate" "Gemini call timed out after ${TIMEOUT}s" \
      "Check network/proxy reachability, then retry. Raise the budget with DD_DASH_PREFLIGHT_TIMEOUT=180."
  else
    needed_by "iterate" "Gemini call failed: $(printf '%s' "$SMOKE_OUT" | head -2 | tr '\n' ' ')" \
      "llm keys set gemini   (a rejected key is the usual cause; also check ALL_PROXY)"
  fi
fi

# --- chart-room ---------------------------------------------------------------
# An internally-distributed compiled binary. There is no public installer to call,
# so this can only ever be surfaced.
print_header "chart-room CLI"
if have chart-room; then
  ok "chart-room v$(run_with_timeout 30 chart-room --version 2>/dev/null || echo unknown) at $(command -v chart-room)"
else
  needed_by "create,expand,iterate" "chart-room not on PATH" \
    "Install the chart-room CLI and put it on PATH (usually ~/.local/bin). It is the only path between a local .dash.json and Datadog -- init, test, prod and status all go through it."
fi

# --- Datadog credentials ------------------------------------------------------
# Secrets: surface, never repair. Validated with a real API call because an
# expired or revoked key is set-but-useless, and that failure otherwise appears
# much later as an empty metric search that reads like "the metric doesn't exist".
print_header "Datadog credentials"
DD_SITE_HOST="${DD_SITE:-datadoghq.com}"
if [ -n "${DD_API_KEY:-}" ] && [ -n "${DD_APP_KEY:-}" ]; then
  ok "DD_API_KEY and DD_APP_KEY are set"
  if have curl; then
    DD_CODE="$(run_with_timeout 30 curl -s -o /dev/null -w '%{http_code}' \
      "https://api.${DD_SITE_HOST}/api/v1/validate" \
      -H "DD-API-KEY: ${DD_API_KEY}" -H "DD-APPLICATION-KEY: ${DD_APP_KEY}" 2>/dev/null)"
    case "$DD_CODE" in
      200) ok "Datadog accepted both keys (api.${DD_SITE_HOST})" ;;
      403|401) needed_by "expand,iterate" "Datadog rejected the keys (HTTP ${DD_CODE})" \
                 "The keys are set but invalid or revoked. Reissue at Datadog -> Organization Settings -> API Keys / Application Keys." ;;
      *) deferred "could not validate Datadog keys (HTTP ${DD_CODE:-no response})" \
           "Network or DD_SITE issue; the keys themselves may be fine. DD_SITE is currently '${DD_SITE_HOST}'." ;;
    esac
  fi
else
  [ -n "${DD_API_KEY:-}" ] || needed_by "expand,iterate" "DD_API_KEY not set" \
    "export DD_API_KEY=... in ~/.zshrc  (Datadog -> Organization Settings -> API Keys)"
  [ -n "${DD_APP_KEY:-}" ] || needed_by "expand,iterate" "DD_APP_KEY not set" \
    "export DD_APP_KEY=... in ~/.zshrc  (Datadog -> Organization Settings -> Application Keys)"
fi

# --- Browser stack ------------------------------------------------------------
# Only the iterate loop screenshots anything, so a create run should report these
# without dying on them.
print_header "Browser stack (screenshots)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
if [ -f "$PLUGIN_ROOT/.mcp.json" ]; then
  ok ".mcp.json present at $PLUGIN_ROOT/.mcp.json"
else
  needed_by "iterate" ".mcp.json missing at $PLUGIN_ROOT" \
    "Reinstall the plugin: claude plugin install datadog-dashboards@bradys-marketplace"
fi

if have mise; then
  ok "mise at $(command -v mise)"
  # `mise x node@22` installs on demand, but on demand means "in the middle of a
  # screenshot", where a multi-minute toolchain download looks like a hang.
  if run_with_timeout 30 sh -c 'mise ls node 2>/dev/null | grep -q "^node *22"'; then
    ok "mise node@22 installed"
  elif [ "$REPAIR" = 1 ]; then
    note "pre-installing mise node@22 so the first screenshot doesn't stall..."
    if run_with_timeout 300 mise install node@22 >/dev/null 2>&1; then
      repaired "installed mise node@22"
    else
      deferred "mise node@22 not pre-installed" \
        "mise install node@22   (otherwise mise fetches it on the first screenshot, which looks like a hang)"
    fi
  else
    deferred "mise node@22 not installed" "mise install node@22"
  fi
else
  if [ "$REPAIR" = 1 ]; then
    note "installing mise..."
    if run_with_timeout "$TIMEOUT" sh -c 'curl -fsSL https://mise.run | sh' >/dev/null 2>&1; then
      PATH="$HOME/.local/bin:$PATH"; export PATH
      have mise && repaired "installed mise to ~/.local/bin" \
                || needed_by "iterate" "mise installed but not on PATH" "Add ~/.local/bin to PATH and restart your shell."
    else
      needed_by "iterate" "mise not installed and auto-install failed" "curl https://mise.run | sh"
    fi
  else
    needed_by "iterate" "mise not on PATH" "curl https://mise.run | sh"
  fi
fi

# Chrome Beta specifically: the MCP launches with --channel=beta so that its
# debug pipe doesn't fight the user's everyday stable Chrome. Stable alone does
# not satisfy it, and a GUI app cannot be installed unattended.
if [ -d "/Applications/Google Chrome Beta.app" ] || have google-chrome-beta; then
  ok "Google Chrome Beta installed"
else
  needed_by "iterate" "Google Chrome Beta not installed" \
    "Install from https://www.google.com/chrome/beta/. The MCP launches with --channel=beta; stable Chrome will not satisfy it."
fi

# --autoConnect attaches to a Chrome that is ALREADY running with the user's
# Datadog session. Not running means the screenshot step fails with a connection
# error that says nothing about "launch your browser".
#
# ASKING THE PROCESS TABLE DOES NOT WORK HERE. This used to be a bare
# `pgrep -f "Google Chrome Beta"`, and inside Claude Code's sandboxed Bash the
# process table is simply not readable:
#
#     sysmon request failed with error: sysmond service not found
#     pgrep: Cannot get process list
#
# pgrep exits 3 (fatal error), `ps -axo comm=` returns zero lines, and
# `osascript` fails with -10810. The old test read all of that as "not running"
# and BLOCKED iterate on machines where Chrome Beta was running and signed in --
# and preflight runs from exactly that sandboxed Bash on every skill invocation,
# so this fired essentially always. Failure A again.
#
# Four probes, most trustworthy first, and pgrep demoted to last because it is
# the one that lies. Anything that cannot answer yields UNKNOWN, which warns
# instead of blocking: an unanswerable question is not a failed dependency.
#
# The ordering is not "cheapest first" -- it is "least able to be wrong first",
# and the two are not the same here. curl looks like the obvious CDP test and is
# in fact the weakest of the four, because in a sandboxed Bash it returns rc=0
# with a zero-byte body whether or not anything is there. Trusting its exit
# status would report Chrome running having learned nothing, which is a FALSE
# POSITIVE -- strictly worse than the false negative this all started as, because
# the run then proceeds and screenshots nothing.
#
# CHROME_EVIDENCE records which probe answered, because they do not all prove the
# same thing: only the CDP ones show the debugging endpoint --autoConnect needs.
# A singleton socket proves Chrome Beta is *alive*, not that it is *attachable*.
#
# 0 = running, 1 = definitively not running, 2 = could not tell
CDP_PORT="${DD_DASH_CDP_PORT:-9222}"
CHROME_EVIDENCE=""
chrome_beta_state() {
  # 1. STRONGEST. lsof reads its own file descriptors rather than the sysmon
  #    process list, so it survives the sandbox, and it answers both questions at
  #    once: is anything listening on the CDP port, and is that thing Beta.
  #
  #    `+c 0` is required. Default lsof truncates COMMAND to 9 characters, so
  #    Chrome Beta and stable Chrome both render as "Google" and the channel --
  #    the entire point of --channel=beta -- becomes unreadable. With +c 0 it
  #    prints in full, spaces escaped as \x20, hence the `Chrome.*Beta` match
  #    rather than a literal space.
  #
  #    A listener that is NOT Beta means someone else holds the port; that is not
  #    evidence either way about Beta, so fall through rather than concluding.
  if have lsof && run_with_timeout 15 sh -c \
       "lsof +c 0 -nP -iTCP:${CDP_PORT} -sTCP:LISTEN 2>/dev/null | grep -qi 'Chrome.*Beta'" ; then
    CHROME_EVIDENCE="CDP listener on port ${CDP_PORT} belongs to Chrome Beta"
    return 0
  fi

  # 2. Chrome's own singleton lock, read straight off the Beta profile. A plain
  #    file read, so it works where the process table does not, and reading the
  #    Beta profile specifically is what keeps stable Chrome from answering for
  #    it. The symlink can outlive a crash, but its target lives in the per-boot
  #    TMPDIR and goes away with the process, so require the target to exist.
  #
  #    Proves liveness, NOT attachability: this is equally true of a Chrome Beta
  #    started with no debugging endpoint, which is precisely the case
  #    --autoConnect fails on. So it answers "running", and CHROME_EVIDENCE says
  #    the attach was not verified.
  local prof sock
  for prof in "$HOME/Library/Application Support/Google/Chrome Beta" \
              "$HOME/.config/google-chrome-beta"; do
    sock="$(readlink "$prof/SingletonSocket" 2>/dev/null)"
    if [ -n "$sock" ] && [ -e "$sock" ]; then
      CHROME_EVIDENCE="Chrome Beta profile singleton socket is live (CDP attach not verified)"
      return 0
    fi
  done

  # 3. curl, and ONLY on a parseable body. rc is worthless: a sandboxed Bash
  #    returns rc=0 with zero bytes whether or not the port is open, and Chrome
  #    serves /json/* only when started with an HTTP debugging endpoint -- a 404
  #    from a real Chrome and an empty reply from nothing look the same through
  #    the exit status. Requiring the JSON body means a positive here is a
  #    positive.
  #
  #    --noproxy is kept because curl honours ALL_PROXY for 127.0.0.1 too, so on
  #    a machine behind a SOCKS proxy without localhost in no_proxy every
  #    loopback probe gets swallowed and reads as "nothing is listening". Where
  #    no_proxy already covers localhost it is simply a no-op.
  if have curl; then
    local body
    body="$(run_with_timeout 15 curl -s --noproxy '*' --max-time 5 \
              "http://127.0.0.1:${CDP_PORT}/json/version" 2>/dev/null)"
    if printf '%s' "$body" | grep -q 'webSocketDebuggerUrl\|"Browser"'; then
      CHROME_EVIDENCE="CDP endpoint on port ${CDP_PORT} answered /json/version"
      return 0
    fi
  fi

  # 4. pgrep last, and only believed when it actually ran. Exit 1 means "ran
  #    fine, matched nothing"; anything else (3 in the sandbox) means it could
  #    not look, which is not the same answer.
  if have pgrep; then
    local err rc
    err="$(pgrep -f "Google Chrome Beta" 2>&1 >/dev/null)"; rc=$?
    if [ "$rc" -eq 0 ]; then
      CHROME_EVIDENCE="a Chrome Beta process is running (CDP attach not verified)"
      return 0
    fi
    [ "$rc" -eq 1 ] && [ -z "$err" ] && return 1
  fi

  return 2
}

chrome_beta_state; CHROME_STATE=$?
case "$CHROME_STATE" in
  0) ok "Chrome Beta is running -- ${CHROME_EVIDENCE}" ;;
  1) needed_by "iterate" "Chrome Beta is not running" \
       "Launch Chrome Beta and sign in to Datadog before iterating. The MCP uses --autoConnect and attaches to a running instance; it will not start one for you." ;;
  *) deferred "could not determine whether Chrome Beta is running" \
       "Nothing is known to be broken -- this environment cannot read the process table and nothing is listening on CDP port ${CDP_PORT}. Make sure Chrome Beta is open and signed in to Datadog before iterating; the screenshot agent will report clearly if it cannot attach." ;;
esac

# --- Shell helpers ------------------------------------------------------------
print_header "Shell helpers"
for tool in jq curl base64; do
  if have "$tool"; then
    ok "$tool at $(command -v "$tool")"
  elif [ "$REPAIR" = 1 ] && have brew && [ "$tool" = "jq" ]; then
    # jq is the only one of the three that is realistically missing and safely
    # installable; curl and base64 ship with macOS, and their absence means
    # something is wrong that this script should not paper over.
    note "installing jq via Homebrew..."
    if run_with_timeout 300 brew install jq >/dev/null 2>&1; then
      repaired "installed jq"
    else
      needed_by "create,expand,iterate" "jq not on PATH" "brew install jq"
    fi
  else
    needed_by "create,expand,iterate" "$tool not on PATH" "brew install $tool"
  fi
done

# --- Summary ------------------------------------------------------------------
print_header "Summary"
STATUS="OK"
[ "$N_REPAIRED" -gt 0 ] && STATUS="REPAIRED"
[ "$N_BLOCKED" -gt 0 ] && STATUS="BLOCKED"

if [ "$N_REPAIRED" -gt 0 ]; then
  printf "${GREEN}${BOLD}Repaired automatically:${NC}\n"
  printf '%b' "$REPAIRS"
  printf '\n'
fi
if [ "$N_DEFERRED" -gt 0 ]; then
  printf "${YELLOW}${BOLD}Not needed yet, but will be:${NC}\n"
  printf '%b' "$DEFERRALS"
  printf '\n'
fi
if [ "$N_BLOCKED" -gt 0 ]; then
  printf "${RED}${BOLD}USER ACTION REQUIRED -- cannot proceed:${NC}\n"
  printf '%b' "$BLOCKERS"
  printf "${RED}These need a human. Run the fixes above, then re-run preflight.${NC}\n"
  printf '\n'
else
  printf "${GREEN}Preflight passed for skill '%s'.${NC}\n" "$SKILL"
fi

# Machine-readable tail. A skill branches on these rather than re-reading the
# prose above, and DEFERRED is included so the skill can warn the user now about
# what the next skill in the chain will hit.
printf '\n'
printf 'PREFLIGHT_STATUS: %s\n' "$STATUS"
printf 'PREFLIGHT_SKILL: %s\n' "$SKILL"
printf 'PREFLIGHT_OK: %s\n' "$N_OK"
printf 'PREFLIGHT_REPAIRED: %s\n' "$N_REPAIRED"
printf 'PREFLIGHT_DEFERRED: %s\n' "$N_DEFERRED"
printf 'PREFLIGHT_BLOCKED: %s\n' "$N_BLOCKED"

[ "$N_BLOCKED" -gt 0 ] && exit 1
exit 0
