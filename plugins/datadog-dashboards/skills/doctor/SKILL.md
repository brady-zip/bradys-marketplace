---
name: doctor
description: Health-check the datadog-dashboards plugin on demand — runs the same preflight every dashboard skill runs as its Phase 0, but across every skill at once, with the full report, and without installing anything. Covers uv, llm + llm-gemini, a live Gemini call, the Datadog keys (validated live), chart-room, mise/node@22, Chrome Beta, and says which skill each failure blocks. Pass `repair` to let it install what it can. Use when the user asks to "check datadog-dashboards", "run the datadog-dashboards preflight", "datadog-dashboards doctor", "why is iterate-dashboard blocked", "is my machine ready for dashboards", or "/datadog-dashboards:doctor".
argument-hint: "[repair]"
allowed-tools: Bash(bash:*), Read
---

# datadog-dashboards doctor

The preflight that `create-dashboard`, `expand-dashboard` and `iterate-dashboard` each run
automatically, run directly — for when a user wants to know the machine's state before
starting a run, or after a skill stopped on `PREFLIGHT_STATUS: BLOCKED`.

Arguments: `$ARGUMENTS`

## 1. Diagnose — this already ran

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-setup.sh" 2>&1 || true`

**The block above already ran** when this skill was invoked; its output is in your context.
Do not run it again. If you see no report above, the injection failed — run it yourself and
continue the same way:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-setup.sh"
```

That is `preflight.sh --skill all --smoke --no-repair`: one implementation, three
differences from what a skill's Phase 0 runs.

- **Every skill at once** (`--skill all`), so one run answers "can I create? expand?
  iterate?" instead of whichever entry point happened to be invoked.
- **Read-only** (`--no-repair`). A doctor reports what is wrong; it does not change the
  machine unless asked (step 2).
- **The full report, not `--brief`.** The passing lines carry versions and *resolved
  paths* — which `uv`, which `llm`, which interpreter its shim points at. Those are what
  diagnose a PATH race, and a PATH race is how this plugin's first diagnostic came to report
  a missing Gemini model on a machine that had it installed for three months.

**It is not free.** A run makes one live Datadog `/api/v1/validate` call (when both keys
are set) and one real, tiny, **billable** Gemini completion — `llm models` listing a gemini
model proves nothing about whether the key works or whether a SOCKS proxy will strangle the
request. `repair` makes a second full run (step 2). Do not loop this skill.

`|| true` is there because the script exits 1 whenever anything is blocked, and a non-zero
inline block aborts the skill before you see the report that explains it. Branch on the
`PREFLIGHT_*` tail, not on an exit code.

## Reading the report — BLOCKED means something different here

In a dashboard skill, `BLOCKED` means *stop this skill*. Here, under `--skill all`, every
problem any skill would hit is reported as `BLOCKED`, and `USER ACTION REQUIRED -- cannot
proceed` means *some skill* cannot proceed — not that this doctor stops. A doctor run that
finds blockers has done its job; finish the report.

Each blocker carries `(needed by: …)`. Use it to tell the user which entry points work
**right now**. Chrome Beta not running blocks `iterate-dashboard` only — `create-dashboard`
still runs. An unset `DD_API_KEY` blocks `expand` and `iterate`. A missing `chart-room`
blocks all three. Do not flatten that into "the plugin is broken".

`DEFERRED` under `--skill all` never means a skill is blocked. It is one of three things,
and the script's wording says which:

- **The probe could not answer** in this environment — Claude Code's sandboxed Bash cannot
  read the process table, and loopback `curl` can be swallowed by a SOCKS `ALL_PROXY`.
  Report it as **could not tell**. Never upgrade it to "broken", never downgrade it to
  "fine".
- **A quirk the script judged non-fatal** — a malformed `uv tool` entry for an `llm` that
  still works, or the preferred Gemini model missing while the fallback answers. Report it
  as a note with its `Fix:` line; it is not a reason to call a skill blocked.
- **A known gap left alone because this run is read-only** — today, `mise node@22 not
  installed`. Nothing is broken yet: `iterate` would fetch it on the first screenshot, a
  multi-minute download that looks like a hang. Report it as **repairable**, and include it
  in step 2's list. It is neither "could not tell" nor harmless.

**A "Gemini live call" section that says `NOT RUN` is not a pass.** The script skips the
live call once anything before it has blocked, because everything before it is on the
Gemini path and the call could only fail for a reason already reported. Report Gemini as
**not checked**, behind the blocker that caused it — never as OK.

**Do not substitute your own judgement for a result.** If the script says Chrome Beta is not
running, you do not decide otherwise because a browser tool exists in this session. If the
user has evidence the script lacks ("Chrome Beta is open, I'm looking at it"), record it next
to the script's result rather than in place of it — a probe that is wrong is a bug in
`scripts/preflight.sh`, and the fix is there, not in the report.

## 2. Repair — only when asked

Run a repair **only if** the arguments above include `repair`, or the user asks you to fix
what was found. Otherwise skip this step.

Before running it, tell the user what it may install: every item the diagnosis reported,
**blocked or deferred**, that the script knows how to install — `uv` (astral installer),
`llm` with `llm-gemini` and `httpx[socks]` (`uv tool install`), `mise`, `node@22` (reported
as deferred, not blocked — easy to miss), and `jq` (Homebrew). Then:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-setup.sh" --repair
```

This is a second full run, with a second Gemini call, and that is the price of telling the
user what will be installed *before* anything is: the inline block cannot see the
arguments, and splicing them into a shell line would let an argument run as a command. The
run re-probes after each install, so its report *is* the post-repair state — no third
run. **List every `REPAIRED` line back to the user.** It is their machine; nothing gets
installed on it silently. If `PREFLIGHT_REPAIRED` is `0` and `DD_DASH_PREFLIGHT_AUTOFIX=0` is
set in the environment, say so: that opt-out disables `--repair` too.

When repair was not requested but something auto-repairable is blocked or deferred, say that
`/datadog-dashboards:doctor repair` would fix it — and that the next dashboard skill's
Phase 0 will repair it anyway, since preflight repairs by default.

**Never act on the human-only items yourself**: the Datadog keys, the Gemini key,
`chart-room`, Chrome Beta. Show each one's `Fix:` line verbatim. Do not run
`llm keys set gemini` for the user — it reads a secret from an interactive prompt.

## 3. Report

One table, one row per area the script printed a header for, named as the script names
it. An area holding several results takes the worst one, and names the item in `Result`:

```
| Area | Result | Blocks | Fix |
|---|---|---|---|
| uv / uvx                    | OK                             | —                    | — |
| Gemini live call            | BLOCKED — key rejected         | iterate              | llm keys set gemini |
| Browser stack (screenshots) | COULD NOT TELL — Chrome Beta   | iterate (if missing) | open Chrome Beta, sign in to Datadog |
```

Then one line per entry point — `create-dashboard`, `expand-dashboard`,
`iterate-dashboard` — saying **ready** or **blocked by** which items. That line is what the
user actually came for.

Then the completion ledger, which every skill in this plugin prints (Rule 2 of the
contract):

```
| Step | Status | Notes |
|---|---|---|
| 1. Diagnose | DONE    | BLOCKED — 2 blockers, 1 could-not-tell, 14 passed |
| 2. Repair   | SKIPPED | not requested; nothing auto-repairable was reported |
| 3. Report   | DONE    | create ready; expand, iterate blocked |
```

`Diagnose` is `DONE` whenever the report came back, healthy or not — the status of the
machine goes in Notes, not in the Status column. It is `FAILED` only if no report came back
at all (script missing, or killed before printing `PREFLIGHT_STATUS`); then say so and
point at `claude plugin install datadog-dashboards@bradys-marketplace`.

As with every ledger in this plugin, a `SKIPPED` or `FAILED` row is restated in prose under
the table, with what the user should do about it.

Full rationale: @${CLAUDE_PLUGIN_ROOT}/knowledge/preflight-contract.md
