# Preflight and Completion Contract

Every skill in this plugin (`create-dashboard`, `expand-dashboard`, `iterate-dashboard`)
obeys the two rules below. They come from one real run that failed in two unrelated ways,
neither of which ever reached the user — they found out by looking at the result.

**Failure A — a diagnostic that was confidently wrong.** The old setup check probed
`uvx llm models | grep -i gemini` and reported no Gemini model on a machine that had
`llm`, `llm-gemini` and a valid key installed for three months. `uvx llm` runs an
ephemeral, plugin-less environment unless uv finds a persistent `llm` tool to reuse — and
whether it does depends on which `uv` wins the PATH race. Nothing was broken except the
question being asked. This is what Rule 1 fixes.

**Failure B — a handoff nobody enforced.** `create-dashboard` finished Phases 1–4, then
did not invoke `expand-dashboard`. No error, no context exhaustion. It had the queries in
hand and continuing inline felt like finishing work in progress. Because expand never ran,
iterate never ran either: no Gemini evaluation, no iteration report. **One skipped line
silently deleted two entire skills from the run.** This is what Rule 2 fixes.

**These two rules are not substitutes for each other.** Failure B was never
environment-blocked — preflight would have gone green and changed nothing about it. A
passing preflight says the machine is fine; it says nothing about whether the run was
complete. Do not let one stand in for the other.

## Rule 1 — Preflight runs on every invocation, and repairs what it can

Each SKILL.md carries this as an inline bash block in its Phase 0:

```
!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh" --skill <create|expand|iterate> --brief 2>&1 || true`
```

Claude Code executes an inline `!` block when the skill is invoked and injects the output
into context, so the check runs whether or not anyone remembers to run it. That is
deliberate: the previous version was an instruction to run a command, and an instruction
is exactly the thing that got skipped.

`|| true` is also deliberate. A non-zero exit from an inline block aborts the entire skill
invocation and the model never sees the skill body — which would turn a BLOCKED preflight
into a bare "shell command failed" and throw away the remediation text. With `|| true` the
report is always injected, and the stop is driven by the `PREFLIGHT_STATUS` line, which
the model can actually read out to the user.

`--brief` exists so that paying this cost on every run is actually affordable in context: a
healthy machine reports two lines instead of forty. It elides only the list of checks that
*passed*. On any non-OK status the repaired / deferred / `USER ACTION REQUIRED` blocks print
in full, and the complete report is written to a log file whose path comes back as
`PREFLIGHT_LOG:`. Drop `--brief`, or `cat` that log, when a check itself looks wrong.

**Every time.** Not once per session, not "if it looks like it already passed", not
"the user just ran it". This plugin ships to people who don't know its internals, on
machines that drift between runs — a wiped `uv tool` directory, an expired Datadog key,
a Chrome Beta that isn't running today. A result from five minutes ago is not evidence
about now, and the script is deliberately cheap enough to pay for on each run.

The script installs what it can install without a human decision (`uv`, `llm` +
`llm-gemini`, `mise`, `node@22`, `jq`) and is idempotent, so a healthy machine no-ops.

### Reading the result

The last lines of output are machine-readable:

```
PREFLIGHT_STATUS: OK | REPAIRED | BLOCKED
PREFLIGHT_OK / PREFLIGHT_REPAIRED / PREFLIGHT_DEFERRED / PREFLIGHT_BLOCKED: <count>
```

| Status | What you do |
|---|---|
| `OK` | Say so in one line, then proceed. |
| `REPAIRED` | **Tell the user what was installed on their machine**, then proceed. Never install things silently — it is their machine. |
| `BLOCKED` | **STOP.** Show the user the `USER ACTION REQUIRED` block verbatim, including the exact fix commands. Do not start the workflow. Do not improvise a workaround. |

If `PREFLIGHT_DEFERRED > 0`, tell the user now which dependency the *next* skill in the
chain will hit, even though this one can proceed. Finding out at the handoff is the
failure this whole contract exists to prevent.

### The one thing you may never do

**Do not substitute your own judgement for a missing dependency.** If Gemini is
unavailable, you do not evaluate the dashboard yourself. If the browser MCP is
unavailable, you do not describe what you think the dashboard looks like. A degraded run
that looks successful is worse than a run that stops, because the user cannot tell the
difference.

## Rule 2 — Report every phase, including the ones you skipped

At the end of every skill invocation, print a completion ledger — one row per phase the
skill defines, no exceptions, in order:

```
## Completion ledger

| Phase | Status | Notes |
|---|---|---|
| 0. Preflight       | DONE    | OK — 15 checks passed |
| 1. Intent          | DONE    | 4 intent questions recorded |
| 2. Structure       | DONE    | 5 sections, layout_type=ordered |
| 3. chart-room init | DONE    | test + prod provisioned |
| 4. Record _meta    | DONE    | _meta written to checkout.dash.json |
| 5. Handoff         | SKIPPED | user asked to stop after init |
```

`Status` is `DONE`, `SKIPPED`, or `FAILED`. **A `SKIPPED` or `FAILED` row must carry a
reason in Notes.** Skipping a phase is allowed — a user can legitimately want to stop
early. Skipping it *without telling anyone* is what is forbidden.

Before printing the ledger, walk the skill's phase list and check each one against what
you actually did. Do not reconstruct it from memory of what you intended to do.

If any row is `SKIPPED` or `FAILED`, restate those rows in prose beneath the table so
they are visible to someone who skims past a markdown table, and say what the user should
do about each.
